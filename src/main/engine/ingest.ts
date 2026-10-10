/**
 * Merge a run of candidates into the library. Port of ingest.py with the changes the brief asks
 * for: rows are filed as soon as the run starts (clip not yet present) and clips fill in as they
 * arrive; pruning happens once, when the run finishes; a run interrupted by quitting resumes and
 * skips clips already on disk; every failure is one health line per run.
 *
 * Nothing here talks to the network directly. `resolve` (search → upload), `download` (upload →
 * file + info) and `clip` are injected so the engine can wire yt-dlp and ffmpeg, and tests can
 * use local files.
 */
import { promises as fs } from 'node:fs'
import { join, basename, extname } from 'node:path'
import { slugify } from './ids'
import { Store } from './store'
import { record, clearKind } from './health'
import { detect, type HookResult } from './hook'
import { parseTs, newerStamp, validRunStamp, EMPTY_LIBRARY, type Candidate, type Library, type Track, type Favourites, type Profile } from './library'

export const TRACK_FIELDS = ['title', 'artist', 'platform', 'direction', 'uses', 'bpm', 'energy', 'mood', 'suits', 'profiles', 'licence', 'notes', 'source_url'] as const

export interface DryRunSummary {
  run: string
  candidates: number
  new: number
  known: number
  keepRuns: number
  duplicateIds: number
}

/** Read-only: the same five numbers `ingest.py --dry-run` prints. */
export function dryRun(library: Library, candidates: Candidate[], run: string, keepRuns: number): DryRunSummary {
  const known = new Set(library.tracks.map((t) => t.id))
  const ids = candidates.map((c) => slugify(c.artist, c.title))
  const fresh = ids.filter((i) => !known.has(i)).length
  return { run, candidates: candidates.length, new: fresh, known: candidates.length - fresh, keepRuns, duplicateIds: ids.length - new Set(ids).size }
}

function isEmptyValue(v: unknown): boolean {
  return v === null || v === undefined || v === '' || (Array.isArray(v) && v.length === 0)
}

/** ingest.merge: file or update one track's metadata row. Clip and hook fields are optional. */
export function mergeTrack(
  library: Library,
  cand: Candidate,
  trackId: string,
  runStamp: string,
  clipRel: string | null,
  clipBytes: number,
  hook?: HookResult
): Track {
  let rec = library.tracks.find((t) => t.id === trackId)
  if (!rec) {
    rec = { id: trackId, first_seen: runStamp, runs: [], clip: null, clip_present: false }
    library.tracks.push(rec)
  }
  for (const field of TRACK_FIELDS) {
    const v = cand[field]
    if (!isEmptyValue(v)) {
      // A link the user set by hand is never overwritten by a later feed run.
      if (field === 'source_url' && rec.user_source_url) continue
      ;(rec as Record<string, unknown>)[field] = v
    }
  }
  rec.mood ??= []
  rec.profiles ??= []
  rec.licence ??= 'platform'
  rec.last_seen = runStamp
  if (!rec.runs.includes(runStamp)) rec.runs = [...new Set([...rec.runs, runStamp])].sort().slice(-24)

  if (cand.uses !== undefined && cand.uses !== null) {
    const hist = (rec.uses_history ??= {})
    hist[runStamp] = cand.uses
    for (const stale of Object.keys(hist).sort().slice(0, -24)) delete hist[stale]
  }
  if (clipRel) {
    rec.clip = clipRel
    rec.clip_present = true
    rec.clip_bytes = clipBytes
  }
  if (hook) {
    rec.hook_at = Math.round(hook.at * 10) / 10
    rec.hook_method = hook.method
    rec.hook_detail = hook.detail
  }
  if (cand.pin) rec.pinned = true
  return rec
}

/**
 * ingest.prune: keep a clip if the track is pinned, a favourite, seen in one of the last
 * `keepRuns` dated runs, or seen in the run just ingested. Only ever sweeps <known-id>.mp3.
 */
export async function prune(library: Library, root: string, favourites: Set<string>, keepRuns: number, currentRun: string | undefined): Promise<{ kept: number; freed: number }> {
  const dated = [...new Set(library.tracks.flatMap((t) => t.runs ?? []).filter(validRunStamp))].sort()
  const recent = new Set(keepRuns > 0 ? dated.slice(-keepRuns) : [])
  if (currentRun) recent.add(currentRun)

  const knownIds = new Set(library.tracks.map((t) => t.id))
  let freed = 0
  let kept = 0
  for (const track of library.tracks) {
    if (!track.clip_present || !track.clip) continue
    if (track.pinned || favourites.has(track.id) || (track.runs ?? []).some((r) => recent.has(r))) {
      kept++
      continue
    }
    const clipPath = join(root, track.clip)
    const st = await fs.stat(clipPath).catch(() => undefined)
    if (st) {
      freed += st.size
      await fs.rm(clipPath, { force: true })
    }
    track.clip_present = false
    delete track.clip_bytes
  }

  const referenced = new Set(library.tracks.filter((t) => t.clip_present && t.clip).map((t) => basename(t.clip!)))
  const clipsDir = join(root, 'clips')
  const entries = await fs.readdir(clipsDir, { withFileTypes: true }).catch(() => [])
  for (const e of entries) {
    if (!e.isFile() || extname(e.name) !== '.mp3') continue
    const stem = e.name.slice(0, -4)
    if (knownIds.has(stem) && !referenced.has(e.name)) {
      const p = join(clipsDir, e.name)
      const st = await fs.stat(p).catch(() => undefined)
      if (st) freed += st.size
      await fs.rm(p, { force: true })
    }
  }
  return { kept, freed }
}

// ------------------------------------------------------------------ the run itself

export interface ResolvedUpload {
  videoId: string
  url: string
  title: string
  channel: string
  duration: number | null
}

export interface DownloadedSource {
  /** Path of the downloaded (or local) audio file. */
  path: string
  /** yt-dlp info dict, when there is one. */
  info?: { heatmap?: unknown; duration?: number; title?: string; channel?: string; uploader?: string; id?: string }
}

export interface IngestDeps {
  /** "artist title" → the first search result that is not in `rejected`. */
  resolve: (search: string, rejected: string[]) => Promise<ResolvedUpload | undefined>
  /** Fetch metadata for a known YouTube URL (title/channel/duration) without downloading. */
  inspect: (url: string) => Promise<ResolvedUpload | undefined>
  /** Download best audio for a URL into `workdir`. */
  download: (url: string, workdir: string) => Promise<DownloadedSource | undefined>
  /** Cut the clip. */
  clip: (src: string, dest: string, hookStart: number) => Promise<{ ok: boolean; error?: string }>
  /** Loudness measurement for the energy hook method. */
  measureRms?: (src: string) => Promise<{ rms: ArrayLike<number>; hop: number; duration: number } | undefined>
  /** Pause between downloads, in ms (the Python used --sleep-requests 2 and 1 s between retries). */
  pauseMs?: number
  /** Called after every state change so the UI can refresh. */
  onProgress?: (p: IngestProgress) => void
  /** Returns true when the user asked to cancel or pause. Checked between tracks. */
  shouldStop?: () => boolean
  /** Which candidates to download audio for; metadata-only runs file rows without downloading. */
  downloadAudio?: boolean
  log?: (line: string) => void
}

export interface IngestProgress {
  run: string
  total: number
  done: number
  current?: string
  phase: 'filing' | 'downloading' | 'pruning' | 'done' | 'stopped'
}

export interface IngestResult {
  run: string
  ok: boolean
  added: number
  updated: number
  no_audio: number
  rejected: number
  clips_kept: number
  bytes_freed: number
  tracked: number
  finished: string
  /** True when the run was stopped before every track was attempted (it stays "in progress"). */
  stopped?: boolean
  no_match?: number
}

export type MatchStatus = 'matched' | 'no-confident-match' | 'no-source' | 'download-failed' | 'local-missing'

/** The match transparency rule: the upload's title or channel must contain the candidate's title or artist. */
export function confidentMatch(upload: { title: string; channel: string }, cand: { title: string; artist: string }): boolean {
  const norm = (s: string) =>
    s
      .normalize('NFKC')
      .toLowerCase()
      .replace(/[^\p{L}\p{N}]+/gu, ' ')
      .trim()
  const hay = `${norm(upload.title)} | ${norm(upload.channel)}`
  const title = norm(cand.title)
  const artist = norm(cand.artist)
  const titleCore = title.replace(/\b(feat|ft|remix|remastered|version|official|video|audio|lyrics)\b/g, '').trim()
  const hits = [title, titleCore, artist].filter((s) => s.length >= 2 && hay.includes(s))
  return hits.length > 0
}

function nowIso(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, '+00:00')
}

/**
 * Run one ingest. `candidates` are already normalised. Resumable: clips already on disk are
 * skipped, so re-running after a quit picks up where it left off without duplicates.
 */
export async function runIngest(store: Store, run: string, candidates: Candidate[], deps: IngestDeps, options: { keepRuns?: number; workRoot?: string } = {}): Promise<IngestResult> {
  const root = store.root
  const log = deps.log ?? (() => undefined)
  const downloadAudio = deps.downloadAudio ?? true
  await fs.mkdir(join(root, 'clips'), { recursive: true })

  const profile = await store.readOr<Profile>('profile.json', {})
  const keepRuns = options.keepRuns ?? Number(profile.retention?.keep_runs ?? 2)

  // 1. Dedupe within the run and file every row straight away.
  const rejected: string[] = []
  const seen = new Map<string, string>()
  const planned: { cand: Candidate; id: string; label: string; clipRel: string; clipPath: string }[] = []
  for (const cand of candidates) {
    const id = slugify(cand.artist, cand.title)
    const label = cand.artist ? `${cand.title} — ${cand.artist}` : cand.title
    if (seen.has(id)) {
      log(`! duplicate of ${seen.get(id)} within this run: ${label} — skipped`)
      rejected.push(`${label} (duplicate of ${seen.get(id)})`)
      continue
    }
    seen.set(id, label)
    planned.push({ cand, id, label, clipRel: `clips/${id}.mp3`, clipPath: join(root, 'clips', `${id}.mp3`) })
  }

  const progress = (p: Partial<IngestProgress>) => deps.onProgress?.({ run, total: planned.length, done: 0, phase: 'filing', ...p })
  progress({ phase: 'filing' })

  const known = new Set<string>()
  await store.update<Library>('library.json', EMPTY_LIBRARY(), (library) => {
    library.version ??= 1
    library.tracks ??= []
    for (const t of library.tracks) known.add(t.id)
    for (const p of planned) {
      mergeTrack(library, p.cand, p.id, run, null, 0)
    }
    library.last_run = newerStamp(library.last_run, run)
    library.updated = nowIso()
    return library
  })

  // 2. Audio, one track at a time, filling in rows as clips arrive.
  const workRoot = options.workRoot ?? join(root, `.work-${process.pid}`)
  await fs.rm(workRoot, { recursive: true, force: true })
  await fs.mkdir(workRoot, { recursive: true })

  let done = 0
  let noAudio = 0
  let noMatch = 0
  let stopped = false
  const outcomes = new Map<string, boolean>()

  try {
    for (const p of planned) {
      if (deps.shouldStop?.()) {
        stopped = true
        break
      }
      progress({ phase: 'downloading', done, current: p.label })
      const existing = await fs.stat(p.clipPath).catch(() => undefined)
      if (existing && existing.size > 0) {
        // Already on disk (resume, or a known track): just make sure the row says so.
        await store.update<Library>('library.json', EMPTY_LIBRARY(), (library) => {
          mergeTrack(library, p.cand, p.id, run, p.clipRel, existing.size)
          library.updated = nowIso()
          return library
        })
        outcomes.set(p.id, true)
        done++
        continue
      }
      if (!downloadAudio) {
        outcomes.set(p.id, false)
        done++
        continue
      }

      const workdir = join(workRoot, p.id)
      await fs.mkdir(workdir, { recursive: true })
      let got = false
      let hook: HookResult | undefined
      let match: Track['match'] | undefined
      let matchUrl: string | undefined
      let matchStatus: MatchStatus = 'no-source'
      try {
        const current = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
        const row = current.tracks.find((t) => t.id === p.id)
        const src = await fetchSource(p.cand, row, workdir, deps, log)
        matchStatus = src.status
        match = src.match
        matchUrl = src.url
        if (src.file) {
          const explicit = p.cand.hook_start !== undefined ? parseTs(p.cand.hook_start) : undefined
          hook = await detect({
            info: src.file.info,
            explicit,
            measureRms: deps.measureRms ? () => deps.measureRms!(src.file!.path) : undefined
          })
          log(`  · hook at ${hook.at}s (${hook.method}: ${hook.detail})`)
          const r = await deps.clip(src.file.path, p.clipPath, hook.at)
          got = r.ok
          if (!r.ok) log(`  ! transcode failed: ${r.error ?? ''}`)
        }
      } finally {
        await fs.rm(workdir, { recursive: true, force: true })
      }

      const size = got ? (await fs.stat(p.clipPath)).size : 0
      await store.update<Library>('library.json', EMPTY_LIBRARY(), (library) => {
        const rec = mergeTrack(library, p.cand, p.id, run, got ? p.clipRel : null, size, got ? hook : undefined)
        if (match) {
          rec.match = match
          rec.match_status = rec.user_source_url ? 'user-link' : 'matched'
          if (matchUrl && !rec.user_source_url) rec.source_url = matchUrl
        } else if (matchStatus === 'no-confident-match') {
          rec.match_status = 'no-confident-match'
        }
        library.updated = nowIso()
        return library
      })
      if (!got) {
        noAudio++
        if (matchStatus === 'no-confident-match') noMatch++
      }
      outcomes.set(p.id, got)
      done++
      if (deps.pauseMs) await new Promise((r) => setTimeout(r, deps.pauseMs))
    }
  } finally {
    await fs.rm(workRoot, { recursive: true, force: true })
  }

  // 3. Prune once, when the run finishes. A stopped run stays in progress and is not pruned.
  let kept = 0
  let freed = 0
  let tracked = 0
  const added = planned.filter((p) => !known.has(p.id) && outcomes.get(p.id)).length
  const updated = planned.filter((p) => known.has(p.id) && outcomes.get(p.id)).length
  if (!stopped) {
    progress({ phase: 'pruning', done })
    await store.withLock(async () => {
      const library = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
      const favourites = new Set((await store.readOr<Favourites>('favourites.json', { ids: [] })).ids ?? [])
      const r = await prune(library, root, favourites, keepRuns, run)
      kept = r.kept
      freed = r.freed
      tracked = library.tracks.length
      library.updated = nowIso()
      await store.writeUnlocked('library.json', library)
    })
  } else {
    tracked = (await store.readOr<Library>('library.json', EMPTY_LIBRARY())).tracks.length
  }

  const result: IngestResult = {
    run,
    ok: true,
    added,
    updated,
    no_audio: noAudio,
    rejected: rejected.length,
    clips_kept: kept,
    bytes_freed: freed,
    tracked,
    finished: nowIso()
  }
  if (noMatch) result.no_match = noMatch
  if (stopped) result.stopped = true

  if (!stopped) {
    await store.write('last_run.json', result)
    const attempted = added + updated + noAudio
    if (noAudio && !(added || updated)) {
      await record(store, 'ingest', false, `Run ${run} downloaded nothing: ${noAudio} tracks had no audio.`, 'Usually the downloader needs updating, or there is no network.')
    } else if (noAudio) {
      await record(store, 'ingest', false, `Run ${run}: ${noAudio} of ${attempted} had no audio${noMatch ? ` (${noMatch} with no confident match)` : ''}.`)
    } else {
      await clearKind(store, 'ingest')
    }
  }
  progress({ phase: stopped ? 'stopped' : 'done', done })
  return result
}

async function fetchSource(
  cand: Candidate,
  row: Track | undefined,
  workdir: string,
  deps: IngestDeps,
  log: (s: string) => void
): Promise<{ file?: DownloadedSource; match?: Track['match']; url?: string; status: MatchStatus }> {
  if (cand.local) {
    const exists = await fs.stat(cand.local).catch(() => undefined)
    if (exists) return { file: { path: cand.local }, status: 'matched' }
    log(`  ! local file missing: ${cand.local}`)
    return { status: 'local-missing' }
  }

  // A link the user set wins over everything, then the row's known source, then the candidate's.
  let url = row?.user_source_url ?? row?.source_url ?? cand.source_url
  let upload: ResolvedUpload | undefined
  if (!url && cand.search) {
    upload = await deps.resolve(cand.search, row?.rejected_video_ids ?? [])
    if (!upload) {
      log(`  · search found nothing for ${cand.search}`)
      return { status: 'no-source' }
    }
    // Match transparency: neither title nor artist appears → file without audio.
    if (!confidentMatch(upload, cand)) {
      log(`  · no confident match: "${upload.title}" by ${upload.channel}`)
      return { match: undefined, status: 'no-confident-match' }
    }
    url = upload.url
  }
  if (!url) {
    log('  · no source_url or search — filing metadata only')
    return { status: 'no-source' }
  }

  const file = await deps.download(url, workdir)
  if (!file) return { status: 'download-failed' }
  const info = file.info ?? {}
  const match = {
    video_id: upload?.videoId ?? info.id ?? '',
    title: upload?.title ?? info.title ?? '',
    channel: upload?.channel ?? info.channel ?? info.uploader ?? '',
    duration: upload?.duration ?? (typeof info.duration === 'number' ? info.duration : null)
  }
  return { file, match, url, status: 'matched' }
}
