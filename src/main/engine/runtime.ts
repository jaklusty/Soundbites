/**
 * The background runtime: keeps tools installed, checks the feed on launch and every few hours,
 * runs ingest jobs one run at a time (oldest first) with visible progress, pause and cancel,
 * works the promote queue, retries tracks on request, and looks for a newer release once a day.
 * Everything that can fail reports into Needs attention via the engine.
 */
import { EventEmitter } from 'node:events'
import { join } from 'node:path'
import { Engine } from './engine'
import { ToolManager, WEEK_MS, type ToolPaths } from './toolManager'
import { runIngest, type Candidate as IngestCandidate, type IngestDeps } from './ingest'
import { promoteMany } from './promote'
import { makeClip, measureRms, transcodeFull } from './media'
import * as ytdlp from './ytdlp'
import { readerFor, parseIndex, parseRunFile, planRuns, ingestedRuns, pendingRunFiles, archivePendingFile, updateFeedState, FeedError, EMPTY_FEED_STATE, type FeedState, type PlannedRun } from './feed'
import { EMPTY_LIBRARY, normalizeCandidate, type Library, type Profile, type Track } from './library'
import { checkForNewerRelease } from './updateCheck'
import { record, clearKind } from './health'
import type { Platform } from './tools'

export interface RuntimeOptions {
  toolsDir: string
  ffmpegPath: string
  platform: Platform
  arch: 'arm64' | 'x64'
  fetchImpl?: typeof fetch
  /** Injectable yt-dlp functions for tests. */
  ytdlpImpl?: Partial<Pick<typeof ytdlp, 'resolveSearch' | 'inspect' | 'downloadAudio' | 'downloadFull'>>
  skipTools?: boolean
  now?: () => Date
  log?: (line: string) => void
}

type Job =
  | { kind: 'run'; run: string; candidates: IngestCandidate[]; audio: boolean; source: 'feed' | 'pending'; path?: string }
  | { kind: 'track'; id: string }

export const FEED_INTERVAL_MS = 3 * 3600 * 1000
export const UPDATE_INTERVAL_MS = 24 * 3600 * 1000

export class Runtime extends EventEmitter {
  readonly tools: ToolManager
  private readonly engine: Engine
  private readonly opts: RuntimeOptions
  private queue: Job[] = []
  private working = false
  private promoting = false
  private promoteAgain = false
  paused = false
  private cancelled = false
  private timers: NodeJS.Timeout[] = []
  private toolPaths: ToolPaths = {}
  private lastYtdlpVersion: string | undefined
  private extractorFailures = 0
  private toolCheckInFlight = false
  private readonly log: (line: string) => void

  constructor(engine: Engine, opts: RuntimeOptions) {
    super()
    this.engine = engine
    this.opts = opts
    this.log = opts.log ?? (() => undefined)
    this.tools = new ToolManager({ toolsDir: opts.toolsDir, platform: opts.platform, arch: opts.arch, fetchImpl: opts.fetchImpl as never, log: this.log })
    engine.on('promote-queued', () => this.kickPromote())
  }

  private now(): Date {
    return this.opts.now ? this.opts.now() : new Date()
  }

  // ------------------------------------------------------------------ lifecycle

  async start(): Promise<void> {
    await this.ensureTools(false)
    this.timers.push(setInterval(() => void this.checkFeed(), FEED_INTERVAL_MS))
    this.timers.push(setInterval(() => void this.ensureTools(true), 6 * 3600 * 1000))
    this.timers.push(setInterval(() => void this.checkForUpdate(), UPDATE_INTERVAL_MS))
    for (const t of this.timers) t.unref()
    void this.checkForUpdate()
    await this.checkFeed()
    this.kickPromote()
  }

  stop(): void {
    for (const t of this.timers) clearInterval(t)
    this.timers = []
    this.cancelled = true
    this.queue = []
  }

  /** The library changed (another folder opened): drop queued work for the old one. */
  reset(): void {
    this.queue = []
    this.cancelled = true
    this.engine.feed = { runsWaiting: 0, archiveRuns: 0, queueLength: 0 }
    this.engine.push()
  }

  // ------------------------------------------------------------------ tools

  async ensureTools(checkForNewer: boolean): Promise<ToolPaths> {
    if (this.opts.skipTools) return this.toolPaths
    const s = this.engine.settings.current
    const weeklyDue = !s.toolsCheckedAt || this.now().getTime() - Date.parse(s.toolsCheckedAt) > WEEK_MS
    const check = checkForNewer || weeklyDue
    if (this.toolCheckInFlight) return this.toolPaths
    this.toolCheckInFlight = true
    try {
      const before = this.tools.versions(this.toolPaths).ytdlp
      this.toolPaths = await this.tools.ensure(check)
      if (check) await this.engine.settings.update({ toolsCheckedAt: this.now().toISOString() })
      const v = this.tools.versions(this.toolPaths)
      this.engine.tools = { ytdlp: v.ytdlp, deno: v.deno, ffmpeg: 'bundled', message: this.tools.lastMessage }
      if (this.tools.lastMessage) await this.engine.recordIssue('tools', this.tools.lastMessage)
      else if (this.engine.store) await clearKind(this.engine.store, 'tools')
      // A newer yt-dlp: retry tracks left without audio, once.
      if (before && v.ytdlp && before !== v.ytdlp) await this.retryNoAudio()
      this.lastYtdlpVersion = v.ytdlp
      this.engine.push()
    } finally {
      this.toolCheckInFlight = false
    }
    return this.toolPaths
  }

  private onExtractorFailure = (detail: string): void => {
    this.extractorFailures++
    if (this.extractorFailures === 1) {
      this.log(`extractor failure: ${detail}; checking for a newer yt-dlp`)
      void this.ensureTools(true)
    }
  }

  private async ytdlpOptions(): Promise<ytdlp.YtDlpOptions | undefined> {
    if (this.opts.skipTools) return { paths: { ytdlp: 'yt-dlp', deno: undefined, ffmpeg: this.opts.ffmpegPath }, sleepRequests: 0, log: this.log }
    const missing = await this.tools.verifyPresent(this.toolPaths)
    if (missing) {
      await this.engine.recordIssue('tools', missing)
      this.toolPaths = await this.tools.ensure(false)
    }
    if (!this.toolPaths.ytdlp) return undefined
    const s = this.engine.settings.current
    return { paths: { ytdlp: this.toolPaths.ytdlp, deno: this.toolPaths.deno, ffmpeg: this.opts.ffmpegPath }, sleepRequests: Math.round(s.requestPauseMs / 1000), log: this.log, onExtractorFailure: this.onExtractorFailure }
  }

  private async ingestDeps(): Promise<IngestDeps | undefined> {
    const o = await this.ytdlpOptions()
    if (!o) return undefined
    const y = { ...ytdlp, ...(this.opts.ytdlpImpl ?? {}) }
    const ffmpeg = this.opts.ffmpegPath
    return {
      resolve: (search, rejected) => y.resolveSearch(o, search, rejected),
      inspect: (url) => y.inspect(o, url),
      download: (url, workdir) => y.downloadAudio(o, url, workdir),
      clip: (src, dest, at) => makeClip(ffmpeg, src, dest, at),
      measureRms: (src) => measureRms(ffmpeg, src),
      pauseMs: 0,
      shouldStop: () => this.cancelled || this.paused,
      log: this.log
    }
  }

  // ------------------------------------------------------------------ feed

  async checkFeed(): Promise<void> {
    const engine = this.engine
    const store = engine.store
    if (!store || !engine.isOpen) return
    const base = engine.settings.current.feedBase
    const nowIso = this.now().toISOString()
    try {
      const reader = readerFor(base, this.opts.fetchImpl)
      const index = parseIndex(await reader.text('index.json'))
      const done = await ingestedRuns(store)
      const profile = await store.readOr<Profile>('profile.json', {})
      const keepRuns = Number(profile.retention?.keep_runs ?? 8)
      const planned = planRuns(index, done, keepRuns, this.now())
      let queued = 0
      for (const p of planned) {
        if (this.queue.some((j) => j.kind === 'run' && j.run === p.run)) continue
        try {
          const parsed = parseRunFile(await reader.text(p.file), p.run)
          await updateFeedState(store, (s) => {
            const existing = s.runs[p.run]
            s.runs[p.run] = { ...(existing ?? {}), state: existing?.state === 'in-progress' ? 'in-progress' : 'queued', file: p.file, count: parsed.candidates.length, audio: p.audio, source: 'feed' }
          })
          this.queue.push({ kind: 'run', run: p.run, candidates: parsed.candidates, audio: p.audio, source: 'feed' })
          queued++
        } catch (err) {
          await engine.recordIssue('feed', `Run ${p.run} could not be read from the feed: ${(err as Error).message}`)
        }
      }
      await updateFeedState(store, (s) => {
        s.lastChecked = nowIso
        s.lastResult = queued ? `${queued} run(s) queued` : 'up to date'
      })
      engine.feed = { ...engine.feed, lastChecked: nowIso, lastResult: queued ? `${queued} new` : 'up to date', archiveRuns: planned.filter((x) => x.archive).length }
      await clearKind(store, 'feed-unreachable')
    } catch (err) {
      const e = err as FeedError
      if (e.code === 'needs-newer-app') await engine.recordIssue('feed', 'This feed needs a newer version of the app.')
      else if (e.code === 'bad-index') await engine.recordIssue('feed', `The feed index could not be read: ${e.message}`)
      else {
        // Offline is normal: say when the feed was last checked and carry on.
        const state = await store.readOr<FeedState>('feed_state.json', EMPTY_FEED_STATE())
        engine.feed = { ...engine.feed, lastChecked: state.lastChecked, lastResult: 'feed not reachable' }
      }
    }
    await this.scanPending()
    await engine.settings.update({ feedCheckedAt: nowIso })
    this.updateFeedCounts()
    void this.work()
  }

  /** Run files dropped into pending/, ordered by their run field. */
  private async scanPending(): Promise<void> {
    const engine = this.engine
    const store = engine.store
    if (!store || !engine.libraryPath) return
    const { ok, bad } = await pendingRunFiles(engine.libraryPath)
    for (const b of bad) await engine.recordIssue('pending', `${b.path.split(/[\\/]/).pop()} in pending/ could not be read and was left where it is (${b.error}).`)
    if (!bad.length) await clearKind(store, 'pending')
    const done = await ingestedRuns(store)
    for (const f of ok) {
      if (this.queue.some((j) => j.kind === 'run' && j.run === f.run)) continue
      try {
        const parsed = parsePendingFile(f.text, f.run)
        if (done.has(f.run)) {
          // Already ingested (for example by the feed): file it away rather than re-ingesting.
          await archivePendingFile(f.path)
          continue
        }
        await updateFeedState(store, (s) => {
          s.runs[f.run] = { ...(s.runs[f.run] ?? {}), state: s.runs[f.run]?.state === 'in-progress' ? 'in-progress' : 'queued', count: parsed.candidates.length, audio: true, source: 'pending' }
        })
        this.queue.push({ kind: 'run', run: f.run, candidates: parsed.candidates, audio: true, source: 'pending', path: f.path })
      } catch (err) {
        await engine.recordIssue('pending', `${f.path.split(/[\\/]/).pop()} in pending/ could not be read and was left where it is (${(err as Error).message}).`)
      }
    }
  }

  private updateFeedCounts(): void {
    const runs = this.queue.filter((j) => j.kind === 'run').length
    this.engine.feed = { ...this.engine.feed, runsWaiting: runs, queueLength: this.queue.length }
    this.engine.push()
  }

  // ------------------------------------------------------------------ the queue

  pause(paused: boolean): void {
    this.paused = paused
    this.engine.feed = { ...this.engine.feed, downloading: this.engine.feed.downloading ? { ...this.engine.feed.downloading, paused } : undefined }
    this.engine.push()
    if (!paused) void this.work()
  }

  cancel(): void {
    this.cancelled = true
    this.queue = []
    this.updateFeedCounts()
  }

  /** Try again / Get clip again for one track. */
  async retryTrack(id: string): Promise<void> {
    if (!this.queue.some((j) => j.kind === 'track' && j.id === id)) this.queue.push({ kind: 'track', id })
    this.updateFeedCounts()
    void this.work()
  }

  private async retryNoAudio(): Promise<void> {
    const store = this.engine.store
    if (!store) return
    const lib = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
    for (const t of lib.tracks) {
      if (!t.clip_present && (t.user_source_url || t.source_url || (t.artist && t.title))) await this.retryTrack(t.id)
    }
  }

  private async work(): Promise<void> {
    if (this.working || this.paused) return
    this.working = true
    this.cancelled = false
    try {
      while (this.queue.length && !this.cancelled && !this.paused && this.engine.isOpen) {
        const job = this.queue[0]!
        if (job.kind === 'run') await this.runJob(job)
        else await this.trackJob(job)
        if (this.queue[0] === job) this.queue.shift()
        this.updateFeedCounts()
      }
    } finally {
      this.working = false
      this.engine.feed = { ...this.engine.feed, downloading: undefined }
      this.updateFeedCounts()
      this.kickPromote()
    }
  }

  private async runJob(job: Extract<Job, { kind: 'run' }>): Promise<void> {
    const engine = this.engine
    const store = engine.store
    if (!store) return
    const deps = await this.ingestDeps()
    if (!deps) {
      await engine.recordIssue('tools', 'Downloads are waiting: the downloader (yt-dlp) is not installed yet. It is fetched automatically when the network is available.')
      this.queue = this.queue.filter((j) => j !== job)
      return
    }
    await updateFeedState(store, (s) => {
      s.runs[job.run] = { ...(s.runs[job.run] ?? { audio: job.audio, source: job.source }), state: 'in-progress', started: s.runs[job.run]?.started ?? this.now().toISOString() }
    })
    const s = engine.settings.current
    const result = await runIngest(store, job.run, job.candidates, {
      ...deps,
      downloadAudio: job.audio,
      onProgress: (p) => {
        engine.feed = { ...engine.feed, downloading: p.phase === 'done' || p.phase === 'stopped' ? undefined : { run: job.run, done: p.done, total: p.total, current: p.current, paused: this.paused } }
        engine.push()
      }
    }, { concurrency: s.concurrency }).catch(async (err: Error) => {
      await engine.recordIssue('ingest', `Run ${job.run} stopped: ${err.message}`)
      await updateFeedState(store, (st) => {
        st.runs[job.run] = { ...(st.runs[job.run] ?? { audio: job.audio, source: job.source }), state: 'failed', error: err.message }
      })
      return undefined
    })
    if (!result) return
    if (result.stopped) {
      // Stays in progress; resumes next time.
      return
    }
    await updateFeedState(store, (st) => {
      st.runs[job.run] = { ...(st.runs[job.run] ?? { audio: job.audio, source: job.source }), state: 'done', finished: this.now().toISOString() }
    })
    if (job.path) await archivePendingFile(job.path).catch(() => undefined)
    this.emit('run-done', job.run, result)
  }

  /** Re-fetch one track's clip, built from its own record: user link, then known source, then a fresh search. */
  private async trackJob(job: Extract<Job, { kind: 'track' }>): Promise<void> {
    const engine = this.engine
    const store = engine.store
    if (!store) return
    const deps = await this.ingestDeps()
    if (!deps) return
    const lib = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
    const t = lib.tracks.find((x) => x.id === job.id)
    if (!t || !t.title) return
    const cand = candidateFromTrack(t)
    const run = t.last_seen ?? t.runs?.[t.runs.length - 1] ?? this.now().toISOString().slice(0, 10)
    const result = await runIngest(store, run, [cand], {
      ...deps,
      onProgress: (p) => {
        engine.feed = { ...engine.feed, downloading: p.phase === 'done' || p.phase === 'stopped' ? undefined : { run: `retry`, done: p.done, total: p.total, current: p.current, paused: this.paused } }
        engine.push()
      }
    }, { keepRuns: 0, skipPrune: true }).catch(async (err: Error) => {
      await engine.recordIssue('downloads', `${t.title}: ${err.message}`)
      return undefined
    })
    if (result && result.no_audio) await engine.recordIssue('downloads', `${t.title}${t.artist ? ` — ${t.artist}` : ''}: still no audio${result.no_match ? ' (no confident match)' : ''}.`)
  }

  // ------------------------------------------------------------------ promotion

  kickPromote(): void {
    if (this.promoting) {
      this.promoteAgain = true
      return
    }
    void this.promoteLoop()
  }

  private async promoteLoop(): Promise<void> {
    const engine = this.engine
    const store = engine.store
    if (!store || this.promoting) return
    this.promoting = true
    try {
      do {
        this.promoteAgain = false
        const queue = await store.readOr<{ ids: string[] }>('promote_queue.json', { ids: [] })
        if (!queue.ids?.length) break
        const o = await this.ytdlpOptions()
        if (!o) break
        const y = { ...ytdlp, ...(this.opts.ytdlpImpl ?? {}) }
        const profile = await store.readOr<Profile>('profile.json', {})
        const format = profile.promote?.format ?? 'wav16'
        await promoteMany(store, queue.ids, format, {
          download: (url, workdir) => y.downloadFull(o, url, workdir),
          transcode: (src, dest, fmt) => transcodeFull(this.opts.ffmpegPath, src, dest, fmt),
          log: this.log
        }, {
          onProgress: (label) => {
            engine.promoting = label
            engine.push()
          },
          shouldStop: () => this.cancelled
        })
        engine.promoting = undefined
        engine.push()
      } while (this.promoteAgain)
    } catch (err) {
      await record(store, 'promote', false, `Full-track download stopped: ${(err as Error).message}`)
    } finally {
      this.promoting = false
      engine.promoting = undefined
      engine.push()
    }
  }

  // ------------------------------------------------------------------ release check

  async checkForUpdate(): Promise<void> {
    const s = this.engine.settings.current
    if (s.updateCheckedAt && this.now().getTime() - Date.parse(s.updateCheckedAt) < UPDATE_INTERVAL_MS) return
    const r = await checkForNewerRelease(this.engine.version, this.opts.fetchImpl)
    await this.engine.settings.update({ updateCheckedAt: this.now().toISOString() })
    this.engine.update = r
    this.engine.push()
  }
}

function parsePendingFile(text: string, run: string): { candidates: IngestCandidate[] } {
  // Hand-dropped files keep local, hook_start, pin and profiles (normalizeCandidate 'pending').
  const data = JSON.parse(text) as { candidates?: unknown[] } | unknown[]
  const raw = Array.isArray(data) ? data : (data.candidates ?? [])
  const candidates: IngestCandidate[] = []
  for (const r of raw) {
    const c = normalizeCandidate((r ?? {}) as never, 'pending')
    if (!('rejected' in c)) candidates.push(c)
  }
  void run
  return { candidates }
}

export function candidateFromTrack(t: Track): IngestCandidate {
  const c: IngestCandidate = { title: t.title ?? '', artist: t.artist ?? '' }
  if (t.user_source_url) c.source_url = t.user_source_url
  else if (t.source_url) c.source_url = t.source_url
  else c.search = `${t.artist ?? ''} ${t.title ?? ''}`.trim()
  for (const k of ['platform', 'direction', 'energy', 'licence', 'notes', 'suits'] as const) if (t[k]) (c as unknown as Record<string, unknown>)[k] = t[k]
  if (t.mood?.length) c.mood = t.mood
  if (typeof t.uses === 'number') c.uses = t.uses
  if (typeof t.bpm === 'number') c.bpm = t.bpm
  return c
}
