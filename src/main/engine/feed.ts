/**
 * The feed client (replaces catchup.py). Reads index.json from an https base or a local folder,
 * keeps feed_state.json in the library, decides which runs to ingest and whether to download
 * audio for them, and picks up run files dropped into pending/.
 */
import { promises as fs } from 'node:fs'
import { join, basename } from 'node:path'
import { Store } from './store'
import { EMPTY_LIBRARY, normalizeCandidate, validRunStamp, type Candidate, type Library, type RawCandidate } from './library'
import { isHttpFeed } from './settings'

export const FEED_VERSION = 1
export const ARCHIVE_DAYS = 21

export interface FeedIndexRun {
  run: string
  file: string
  count?: number
}
export interface FeedIndex {
  version: number
  updated?: string
  runs: FeedIndexRun[]
}
export interface FeedRunFile {
  run: string
  region?: string
  candidates: RawCandidate[]
}

export type RunState = 'queued' | 'in-progress' | 'done' | 'failed'
export interface FeedStateEntry {
  state: RunState
  file?: string
  count?: number
  audio: boolean
  source: 'feed' | 'pending'
  started?: string
  finished?: string
  error?: string
}
export interface FeedState {
  version: 1
  runs: Record<string, FeedStateEntry>
  lastChecked?: string
  lastResult?: string
}

export const EMPTY_FEED_STATE = (): FeedState => ({ version: 1, runs: {} })

export class FeedError extends Error {
  constructor(
    message: string,
    readonly code: 'unreachable' | 'bad-index' | 'needs-newer-app' | 'bad-run'
  ) {
    super(message)
    this.name = 'FeedError'
  }
}

export interface FeedReader {
  text(relativePath: string): Promise<string>
}

/** Reads feed files from an https base URL. */
export function httpReader(base: string, fetchImpl: typeof fetch = fetch): FeedReader {
  return {
    async text(rel) {
      let res: Response
      try {
        res = await fetchImpl(new URL(rel, base).toString(), { headers: { 'Cache-Control': 'no-cache' }, signal: AbortSignal.timeout(30_000) })
      } catch (err) {
        throw new FeedError(`Could not reach the feed (${(err as Error).message})`, 'unreachable')
      }
      if (!res.ok) throw new FeedError(`The feed answered ${res.status} for ${rel}`, 'unreachable')
      return res.text()
    }
  }
}

/** Reads feed files from a local folder (tests, or a feed copied by hand). */
export function folderReader(dir: string): FeedReader {
  return {
    async text(rel) {
      const safe = rel.split('/').filter((p) => p && p !== '..' && p !== '.')
      try {
        return await fs.readFile(join(dir, ...safe), 'utf8')
      } catch (err) {
        throw new FeedError(`Could not read ${rel} from the feed folder (${(err as NodeJS.ErrnoException).code ?? 'error'})`, 'unreachable')
      }
    }
  }
}

export function readerFor(base: string, fetchImpl?: typeof fetch): FeedReader {
  return isHttpFeed(base) ? httpReader(base, fetchImpl) : folderReader(base)
}

export function parseIndex(text: string): FeedIndex {
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    throw new FeedError('The feed index is not valid JSON', 'bad-index')
  }
  const d = data as Partial<FeedIndex>
  if (!d || typeof d !== 'object' || !Array.isArray(d.runs)) throw new FeedError('The feed index has no runs list', 'bad-index')
  const version = Number(d.version ?? 1)
  if (version > FEED_VERSION) throw new FeedError('This feed needs a newer version of the app.', 'needs-newer-app')
  const runs = d.runs
    .filter((r): r is FeedIndexRun => !!r && typeof r === 'object' && validRunStamp((r as FeedIndexRun).run) && typeof (r as FeedIndexRun).file === 'string')
    .map((r) => ({ run: r.run, file: r.file, count: typeof r.count === 'number' ? r.count : undefined }))
  // Sort by date ourselves; never trust the feed's order.
  runs.sort((a, b) => (a.run < b.run ? -1 : a.run > b.run ? 1 : 0))
  return { version, updated: typeof d.updated === 'string' ? d.updated : undefined, runs }
}

export function parseRunFile(text: string, expectRun?: string): { run: string; candidates: Candidate[]; rejected: string[] } {
  let data: unknown
  try {
    data = JSON.parse(text)
  } catch {
    throw new FeedError('The run file is not valid JSON', 'bad-run')
  }
  let run: string | undefined
  let raw: RawCandidate[]
  if (Array.isArray(data)) {
    raw = data as RawCandidate[]
    run = expectRun
  } else {
    const d = data as Partial<FeedRunFile>
    run = typeof d?.run === 'string' ? d.run : expectRun
    raw = Array.isArray(d?.candidates) ? d.candidates : []
  }
  if (!validRunStamp(run)) throw new FeedError('The run file has no YYYY-MM-DD run date', 'bad-run')
  const candidates: Candidate[] = []
  const rejected: string[] = []
  for (const r of raw) {
    const c = normalizeCandidate(r ?? {}, 'feed')
    if ('rejected' in c) rejected.push(c.rejected)
    else candidates.push(c)
  }
  return { run, candidates, rejected }
}

/** Runs already handled: done in feed_state.json, or any track in library.json carries the date. */
export async function ingestedRuns(store: Store): Promise<Set<string>> {
  const state = await store.readOr<FeedState>('feed_state.json', EMPTY_FEED_STATE())
  const done = new Set(Object.entries(state.runs).filter(([, e]) => e.state === 'done').map(([k]) => k))
  const library = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
  for (const t of library.tracks) for (const r of t.runs ?? []) if (validRunStamp(r)) done.add(r)
  return done
}

export interface PlannedRun {
  run: string
  file: string
  count?: number
  /** Download clips (newest keep_runs runs) or file metadata only. */
  audio: boolean
  archive: boolean
}

export function ageDays(run: string, today = new Date()): number {
  const t = Date.parse(`${run}T00:00:00Z`)
  return Math.floor((today.getTime() - t) / 86_400_000)
}

/**
 * Which runs to ingest, oldest first, and which get audio: the newest `keepRuns` runs in the
 * whole index (so a first launch never downloads the history). Done runs are skipped.
 * A run already in-progress (quit mid-run) is included again so it resumes.
 */
export function planRuns(index: FeedIndex, done: Set<string>, keepRuns: number, today = new Date()): PlannedRun[] {
  const all = index.runs
  const withAudio = new Set(all.slice(-Math.max(0, keepRuns)).map((r) => r.run))
  return all
    .filter((r) => !done.has(r.run))
    .map((r) => ({ run: r.run, file: r.file, count: r.count, audio: withAudio.has(r.run), archive: ageDays(r.run, today) > ARCHIVE_DAYS }))
}

/** Run files the user dropped into pending/, ordered by their `run` field, not their file name. */
export async function pendingRunFiles(libraryRoot: string): Promise<{ ok: { path: string; run: string; text: string }[]; bad: { path: string; error: string }[] }> {
  const dir = join(libraryRoot, 'pending')
  const names = (await fs.readdir(dir).catch(() => [])).filter((n) => n.toLowerCase().endsWith('.json')).sort()
  const ok: { path: string; run: string; text: string }[] = []
  const bad: { path: string; error: string }[] = []
  for (const n of names) {
    const path = join(dir, n)
    try {
      const text = await fs.readFile(path, 'utf8')
      const parsed = JSON.parse(text) as Partial<FeedRunFile> | unknown[]
      const run = Array.isArray(parsed) ? n.replace(/\.json$/i, '') : (parsed as Partial<FeedRunFile>).run
      if (!validRunStamp(run)) throw new Error('no YYYY-MM-DD run date')
      ok.push({ path, run, text })
    } catch (err) {
      bad.push({ path, error: (err as Error).message })
    }
  }
  ok.sort((a, b) => (a.run < b.run ? -1 : a.run > b.run ? 1 : 0))
  return { ok, bad }
}

/** After a successful ingest, move the dropped file to pending/ingested/ (never overwrite). */
export async function archivePendingFile(path: string): Promise<void> {
  const dir = join(path, '..', 'ingested')
  await fs.mkdir(dir, { recursive: true })
  let dest = join(dir, basename(path))
  if (await fs.stat(dest).catch(() => undefined)) {
    const stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(8, 14)
    dest = join(dir, basename(path).replace(/\.json$/i, `-${stamp}.json`))
  }
  await fs.rename(path, dest)
}

export async function updateFeedState(store: Store, fn: (s: FeedState) => void): Promise<FeedState> {
  return store.update<FeedState>('feed_state.json', EMPTY_FEED_STATE(), (s) => {
    s.runs ??= {}
    fn(s)
    return s
  })
}
