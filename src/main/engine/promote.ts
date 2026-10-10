/**
 * Full tracks for starred items. Port of promote.py: download the whole track, keep the original,
 * transcode to the profile's format into full/<id>/, write only this module's own fields under
 * the lock afterwards. Reclaim deletes full tracks for unstarred entries only.
 * Starring is the only trigger (hard requirement 8); the caller decides when to run this.
 */
import { promises as fs } from 'node:fs'
import { join, extname, relative } from 'node:path'
import { Store } from './store'
import { record, clearKind } from './health'
import { EMPTY_LIBRARY, safeMediaUrl, type Library, type Favourites, type Track } from './library'
import { FULL_FORMATS } from './media'

export interface PromoteDeps {
  download: (url: string, workdir: string) => Promise<{ path: string } | undefined>
  transcode: (src: string, dest: string, format: string) => Promise<{ ok: boolean; error?: string }>
  log?: (line: string) => void
}

export type PromoteStatus = 'ok' | 'already' | 'no-source' | 'download-failed' | 'transcode-failed' | 'unknown'

export async function promoteOne(store: Store, track: Track, format: string, deps: PromoteDeps, workRoot?: string): Promise<{ status: PromoteStatus; path?: string }> {
  const root = store.root
  const fmt = FULL_FORMATS[format] ? format : 'wav16'
  const ext = FULL_FORMATS[fmt]!.ext
  const destDir = join(root, 'full', track.id)
  const dest = join(destDir, `${track.id}.${ext}`)

  const st = await fs.stat(dest).catch(() => undefined)
  if (st && st.size > 0) return { status: 'already', path: dest }

  const url = safeMediaUrl(track.user_source_url ?? track.source_url)
  if (!url) return { status: 'no-source' }

  await fs.mkdir(destDir, { recursive: true })
  const workdir = join(workRoot ?? join(root, '.work-full'), track.id)
  await fs.rm(workdir, { recursive: true, force: true })
  await fs.mkdir(workdir, { recursive: true })
  try {
    const src = await deps.download(url, workdir)
    if (!src) return { status: 'download-failed' }
    // Keep the original: re-transcoding is free, re-downloading may not be possible in six weeks.
    await fs.copyFile(src.path, join(destDir, `${track.id}.source${extname(src.path)}`))
    const r = await deps.transcode(src.path, dest, fmt)
    if (!r.ok) {
      deps.log?.(`  ! transcode failed: ${r.error ?? ''}`)
      return { status: 'transcode-failed' }
    }
    return { status: 'ok', path: dest }
  } finally {
    await fs.rm(workdir, { recursive: true, force: true })
  }
}

export interface PromoteRunResult {
  done: string[]
  failed: { label: string; status: PromoteStatus }[]
  remaining: string[]
  totalBytes: number
  count: number
}

/** Work a list of ids (normally the promote queue). Downloads run with no lock held. */
export async function promoteMany(store: Store, ids: string[], format: string, deps: PromoteDeps, options: { onProgress?: (label: string, i: number, n: number) => void; shouldStop?: () => boolean } = {}): Promise<PromoteRunResult> {
  const library = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
  const byId = new Map(library.tracks.map((t) => [t.id, t]))
  const results = new Map<string, { status: PromoteStatus; path?: string }>()
  const done: string[] = []
  const failed: { label: string; status: PromoteStatus }[] = []

  const wanted = [...new Set(ids)]
  for (let i = 0; i < wanted.length; i++) {
    if (options.shouldStop?.()) break
    const tid = wanted[i]!
    const track = byId.get(tid)
    if (!track) {
      failed.push({ label: tid, status: 'unknown' })
      results.set(tid, { status: 'unknown' })
      continue
    }
    const label = `${track.title ?? tid}${track.artist ? ` — ${track.artist}` : ''}`
    options.onProgress?.(label, i, wanted.length)
    const r = await promoteOne(store, track, format, deps)
    results.set(tid, r)
    if (r.status === 'ok' || r.status === 'already') done.push(label)
    else failed.push({ label, status: r.status })
  }

  // Short critical section: re-read, write only our own fields, re-read the queue.
  let totalBytes = 0
  let count = 0
  let remaining: string[] = []
  await store.withLock(async () => {
    const lib = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
    const map = new Map(lib.tracks.map((t) => [t.id, t]))
    for (const [tid, r] of results) {
      const track = map.get(tid)
      if (!track) continue
      if ((r.status === 'ok' || r.status === 'already') && r.path) {
        track.full = relative(store.root, r.path).split('\\').join('/')
        track.full_format = FULL_FORMATS[format] ? format : 'wav16'
        track.full_bytes = (await fs.stat(r.path)).size
        track.promoted_at = new Date().toISOString().replace(/\.\d{3}Z$/, '+00:00')
        delete track.full_error
      } else {
        track.full_error = r.status
      }
    }
    const queue = await store.readOr<{ ids: string[] }>('promote_queue.json', { ids: [] })
    remaining = (queue.ids ?? []).filter((i) => !results.has(i))
    await store.writeUnlocked('promote_queue.json', { ids: remaining })
    lib.updated = new Date().toISOString().replace(/\.\d{3}Z$/, '+00:00')
    await store.writeUnlocked('library.json', lib)
    totalBytes = lib.tracks.reduce((n, t) => n + (t.full_bytes ?? 0), 0)
    count = lib.tracks.filter((t) => t.full).length
  })

  if (failed.length) {
    await record(store, 'promote', false, `${failed.length} full track(s) could not be downloaded.`, failed.map((f) => `${f.label}: ${f.status}`).join('; ').slice(0, 400))
  } else {
    await clearKind(store, 'promote')
  }
  return { done, failed, remaining, totalBytes, count }
}

/** Add a track to the promote queue (called when the user stars). Returns false if it already has a full track. */
export async function queuePromotion(store: Store, trackId: string): Promise<boolean> {
  const library = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
  const track = library.tracks.find((t) => t.id === trackId)
  if (!track) return false
  if (track.full) return false
  let added = false
  await store.update<{ ids: string[] }>('promote_queue.json', { ids: [] }, (q) => {
    q.ids ??= []
    if (q.ids.includes(trackId)) return undefined
    added = true
    return { ids: [...q.ids, trackId] }
  })
  return added
}

/** promote.py --reclaim: delete full tracks for anything no longer starred. Never touches a favourite or a clip. */
export async function reclaim(store: Store): Promise<{ removed: string[]; freed: number }> {
  const root = store.root
  const removed: string[] = []
  let freed = 0
  await store.withLock(async () => {
    const library = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
    const favourites = new Set((await store.readOr<Favourites>('favourites.json', { ids: [] })).ids ?? [])
    for (const track of library.tracks) {
      if (!track.id || favourites.has(track.id) || !track.full) continue
      const folder = join(root, 'full', track.id)
      const st = await fs.stat(folder).catch(() => undefined)
      if (st?.isDirectory()) {
        freed += await folderSize(folder)
        await fs.rm(folder, { recursive: true, force: true })
      }
      removed.push(track.title ?? track.id)
      delete track.full
      delete track.full_format
      delete track.full_bytes
      delete track.promoted_at
    }
    if (removed.length) {
      library.updated = new Date().toISOString().replace(/\.\d{3}Z$/, '+00:00')
      await store.writeUnlocked('library.json', library)
    }
  })
  return { removed, freed }
}

/** What "Free that space" would reclaim: full tracks for unstarred entries. */
export async function reclaimable(store: Store): Promise<{ count: number; bytes: number }> {
  const library = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
  const favourites = new Set((await store.readOr<Favourites>('favourites.json', { ids: [] })).ids ?? [])
  let count = 0
  let bytes = 0
  for (const t of library.tracks) {
    if (t.full && !favourites.has(t.id)) {
      count++
      bytes += t.full_bytes ?? 0
    }
  }
  return { count, bytes }
}

async function folderSize(dir: string): Promise<number> {
  let total = 0
  const entries = await fs.readdir(dir, { withFileTypes: true }).catch(() => [])
  for (const e of entries) {
    const p = join(dir, e.name)
    if (e.isDirectory()) total += await folderSize(p)
    else if (e.isFile()) total += (await fs.stat(p)).size
  }
  return total
}
