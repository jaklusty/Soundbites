/**
 * The engine: owns the open library, answers every operation the page can ask for, and pushes a
 * fresh state snapshot after each change. Electron-specific pieces (dialogs, shell, drag, the
 * audio protocol) stay in src/main/index.ts; this class is plain Node so it can be tested.
 */
import { EventEmitter } from 'node:events'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { Store, StoreError, type HealthEvent } from './store'
import { LibraryLock } from './libraryLock'
import { Settings, type AppSettings } from './settings'
import { probeLibrary, createLibrary } from './libraryOpen'
import { record, type HealthFile, type HealthRecord } from './health'
import { EMPTY_LIBRARY, type Library, type Favourites, type Profile, type Track } from './library'
import { queuePromotion, reclaim, reclaimable } from './promote'
import { isValidRule } from '../../shared/views'
import type { AppState, LibraryStatus, FeedStatus, ToolsStatus, ViewRule } from '../../shared/ipc'
import type { IngestResult } from './ingest'

export interface EngineOptions {
  appDataDir: string
  version: string
  platform?: NodeJS.Platform
}

export class Engine extends EventEmitter {
  readonly settings: Settings
  readonly version: string
  readonly platform: NodeJS.Platform
  store: Store | undefined
  private lock: LibraryLock | undefined
  private libraryStatus: LibraryStatus = { status: 'none' }
  feed: FeedStatus = { runsWaiting: 0, archiveRuns: 0, queueLength: 0 }
  tools: ToolsStatus = {}
  promoting: string | undefined
  update: AppState['update']
  private pushTimer: NodeJS.Timeout | undefined

  constructor(opts: EngineOptions) {
    super()
    this.settings = new Settings(opts.appDataDir)
    this.version = opts.version
    this.platform = opts.platform ?? process.platform
  }

  get libraryPath(): string | undefined {
    return 'path' in this.libraryStatus ? this.libraryStatus.path : undefined
  }

  get isOpen(): boolean {
    return this.libraryStatus.status === 'open'
  }

  // ------------------------------------------------------------------ lifecycle

  async start(): Promise<void> {
    const s = await this.settings.load()
    if (s.libraryPath) await this.open(s.libraryPath)
  }

  /** Open a folder. Never creates a library; see createHere(). */
  async open(path: string): Promise<LibraryStatus> {
    await this.close()
    const probe = await probeLibrary(path)
    if (probe.status === 'missing') {
      this.libraryStatus = { status: 'missing', path }
    } else if (probe.status === 'not-a-folder') {
      this.libraryStatus = { status: 'error', path, message: 'That is a file, not a folder.' }
    } else if (probe.status === 'empty') {
      this.libraryStatus = { status: 'empty', path, warnings: probe.warnings }
    } else {
      const lock = new LibraryLock(path)
      const r = await lock.acquire()
      if (r.status === 'held') this.libraryStatus = { status: 'held', path, owner: r.owner }
      else if (r.status === 'stale') this.libraryStatus = { status: 'stale', path, owner: r.owner }
      else {
        this.lock = lock
        this.store = new Store(path, { onHealth: (e) => void this.onStoreHealth(e) })
        this.libraryStatus = { status: 'open', path, warnings: probe.warnings }
        // Read once now so a corrupt file is reported (and restored) immediately.
        try {
          await this.store.read('library.json')
          await this.store.read('favourites.json')
          await this.store.read('profile.json')
        } catch (err) {
          const e = err as StoreError
          await this.close()
          this.libraryStatus = { status: 'error', path, message: e.message }
        }
      }
    }
    await this.settings.update({ libraryPath: path })
    this.push()
    return this.libraryStatus
  }

  async createHere(path: string): Promise<LibraryStatus> {
    const probe = await probeLibrary(path)
    if (probe.status !== 'empty') return this.open(path)
    await createLibrary(path)
    return this.open(path)
  }

  async takeOver(): Promise<LibraryStatus> {
    const path = this.libraryPath
    if (!path || this.libraryStatus.status !== 'stale') return this.libraryStatus
    const lock = new LibraryLock(path)
    await lock.takeOver()
    await lock.release()
    return this.open(path)
  }

  async close(): Promise<void> {
    if (this.lock) await this.lock.release()
    this.lock = undefined
    this.store = undefined
    this.libraryStatus = { status: 'none' }
  }

  private async onStoreHealth(e: HealthEvent): Promise<void> {
    // The store reports restores and corruption; keep them in health.json so the strip shows them.
    if (this.store && e.level !== 'info') await record(this.store, 'storage', false, e.message)
    this.push()
  }

  // ------------------------------------------------------------------ state

  /** Debounced push of a fresh snapshot to listeners (the window). */
  push(): void {
    if (this.pushTimer) return
    this.pushTimer = setTimeout(() => {
      this.pushTimer = undefined
      void this.snapshot().then((s) => this.emit('state', s))
    }, 40)
    this.pushTimer.unref()
  }

  async snapshot(): Promise<AppState> {
    const base: AppState = {
      version: this.version,
      platform: this.platform,
      library: this.libraryStatus,
      tracks: [],
      favourites: [],
      promoteQueue: [],
      promoting: this.promoting,
      profile: {},
      activeView: '',
      health: { issues: [], pending: [], reclaimable: { count: 0, bytes: 0 } },
      feed: this.feed,
      tools: this.tools,
      settings: this.settings.current,
      update: this.update
    }
    const store = this.store
    if (!store || this.libraryStatus.status !== 'open') return base
    try {
      const library = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
      const favourites = await store.readOr<Favourites>('favourites.json', { ids: [] })
      const profile = await store.readOr<Profile>('profile.json', {})
      const queue = await store.readOr<{ ids: string[] }>('promote_queue.json', { ids: [] })
      const health = await store.readOr<HealthFile>('health.json', { events: [] })
      const lastRun = await store.readOr<IngestResult | undefined>('last_run.json', undefined)
      const pending = await this.pendingFiles()
      base.tracks = library.tracks
      base.lastRun = library.last_run
      base.favourites = favourites.ids ?? []
      base.promoteQueue = queue.ids ?? []
      base.profile = profile
      base.activeView = profile.views?.active ?? ''
      base.health = {
        issues: (health.events ?? []).filter((e) => !e.ok).slice(-8),
        pending,
        lastRun,
        reclaimable: await reclaimable(store)
      }
    } catch (err) {
      const e = err as StoreError
      base.health.issues = [{ at: new Date().toISOString(), kind: 'storage', ok: false, message: e.message, detail: '' }]
    }
    return base
  }

  async pendingFiles(): Promise<string[]> {
    const path = this.libraryPath
    if (!path) return []
    const entries = await fs.readdir(join(path, 'pending')).catch(() => [])
    return entries.filter((n) => n.toLowerCase().endsWith('.json')).sort()
  }

  // ------------------------------------------------------------------ operations

  private need(): Store {
    if (!this.store || this.libraryStatus.status !== 'open') throw new Error('No library is open')
    return this.store
  }

  /** Star or unstar. Starring is the only thing that queues a full-track download. Returns true if queued. */
  async star(id: string, on: boolean): Promise<boolean> {
    const store = this.need()
    let queued = false
    await store.withLock(async () => {
      const library = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
      if (!library.tracks.some((t) => t.id === id)) throw new Error('No such track')
      const favs = await store.readOr<Favourites>('favourites.json', { ids: [] })
      const ids = new Set(favs.ids ?? [])
      if (on) ids.add(id)
      else ids.delete(id)
      favs.ids = [...ids].sort()
      favs.updated = new Date().toISOString().replace(/\.\d{3}Z$/, '+00:00')
      favs.starred_at ??= {}
      if (on) favs.starred_at[id] ??= favs.updated
      else delete favs.starred_at[id]
      await store.writeUnlocked('favourites.json', favs)
    })
    if (on) queued = await queuePromotion(store, id)
    this.push()
    if (queued) this.emit('promote-queued', id)
    return queued
  }

  async reclaim(): Promise<{ removed: number; freed: number }> {
    const store = this.need()
    const r = await reclaim(store)
    this.push()
    return { removed: r.removed.length, freed: r.freed }
  }

  async setActiveView(key: string): Promise<void> {
    const store = this.need()
    await store.update<Profile>('profile.json', {}, (p) => {
      p.views ??= { saved: {} }
      const saved = p.views.saved ?? {}
      p.views.active = key && saved[key] ? key : ''
      return p
    })
    this.push()
  }

  async saveViewRule(key: string, rule: ViewRule): Promise<void> {
    const store = this.need()
    if (!isValidRule(rule)) throw new Error('That rule has no conditions')
    await store.update<Profile>('profile.json', {}, (p) => {
      p.views ??= { saved: {} }
      p.views.saved ??= {}
      const view = (p.views.saved[key] ??= { label: key })
      view.rule = rule
      return p
    })
    this.push()
  }

  async updateSettings(patch: Partial<AppSettings>): Promise<AppSettings> {
    const before = this.settings.current
    const next = await this.settings.update(patch)
    if (patch.libraryPath && patch.libraryPath !== before.libraryPath) await this.open(patch.libraryPath)
    this.push()
    return next
  }

  async clearIssue(index: number): Promise<void> {
    const store = this.need()
    await store.update<HealthFile>('health.json', { events: [] }, (h) => {
      const bad = (h.events ?? []).filter((e) => !e.ok).slice(-8)
      const target = bad[index]
      if (!target) return undefined
      return { ...h, events: (h.events ?? []).filter((e) => e !== target) }
    })
    this.push()
  }

  /**
   * The user pasted a YouTube link for an existing track. The current clip is removed so the
   * next fetch cuts it from the new upload; the link is never overwritten by a later feed run.
   */
  async setTrackLink(id: string, url: string): Promise<void> {
    const store = this.need()
    const root = store.root
    await store.withLock(async () => {
      const lib = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
      const t = lib.tracks.find((x) => x.id === id)
      if (!t) throw new Error('No such track')
      if (t.clip) await fs.rm(join(root, t.clip), { force: true })
      t.clip_present = false
      delete t.clip_bytes
      delete t.hook_at
      delete t.hook_method
      delete t.hook_detail
      delete t.match
      t.user_source_url = url
      t.source_url = url
      t.match_status = 'user-link'
      lib.updated = new Date().toISOString().replace(/\.\d{3}Z$/, '+00:00')
      await store.writeUnlocked('library.json', lib)
    })
    this.push()
  }

  /** Remove a wrong clip (and optionally the full track), remember the rejected video id. */
  async rejectMatch(id: string, alsoRemoveFull: boolean): Promise<Track | undefined> {
    const store = this.need()
    const root = store.root
    let track: Track | undefined
    await store.withLock(async () => {
      const lib = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
      const t = lib.tracks.find((x) => x.id === id)
      if (!t) throw new Error('No such track')
      const rejectedId = t.match?.video_id || videoIdOf(t.source_url)
      if (rejectedId) {
        t.rejected_video_ids = [...new Set([...(t.rejected_video_ids ?? []), rejectedId])]
      }
      if (t.clip) await fs.rm(join(root, t.clip), { force: true })
      t.clip_present = false
      delete t.clip_bytes
      delete t.hook_at
      delete t.hook_method
      delete t.hook_detail
      delete t.match
      delete t.match_status
      if (!t.user_source_url) delete t.source_url
      if (alsoRemoveFull && t.full) {
        await fs.rm(join(root, 'full', t.id), { recursive: true, force: true })
        delete t.full
        delete t.full_format
        delete t.full_bytes
        delete t.promoted_at
      }
      track = t
      lib.updated = new Date().toISOString().replace(/\.\d{3}Z$/, '+00:00')
      await store.writeUnlocked('library.json', lib)
    })
    this.push()
    return track
  }

  async recordIssue(kind: string, message: string, detail = ''): Promise<void> {
    if (this.store) await record(this.store, kind, false, message, detail)
    this.push()
  }

  issuesSnapshot(): Promise<HealthRecord[]> {
    return this.snapshot().then((s) => s.health.issues)
  }
}

function videoIdOf(url: string | undefined): string | undefined {
  if (!url) return undefined
  const m = /[?&]v=([A-Za-z0-9_-]{11})/.exec(url) ?? /youtu\.be\/([A-Za-z0-9_-]{11})/.exec(url)
  return m ? m[1] : undefined
}
