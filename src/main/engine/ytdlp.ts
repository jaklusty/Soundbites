/**
 * Everything that runs yt-dlp. Argument arrays only, "--" before every URL, bundled ffmpeg via
 * --ffmpeg-location, Deno via --js-runtimes, no remote components, no browser cookies.
 */
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { runTool, lastLine } from './media'
import { YT_ID } from './library'
import type { ResolvedUpload, DownloadedSource } from './ingest'

export interface YtDlpPaths {
  ytdlp: string
  deno: string | undefined
  ffmpeg: string
}

export interface YtDlpOptions {
  paths: YtDlpPaths
  /** Seconds to sleep between requests (yt-dlp --sleep-requests). */
  sleepRequests: number
  log?: (line: string) => void
  /** Called when stderr looks like an extractor failure (a stale yt-dlp). */
  onExtractorFailure?: (detail: string) => void
}

export const SEARCH_TIMEOUT_MS = 120_000
export const DOWNLOAD_TIMEOUT_MS = 180_000
export const FULL_TIMEOUT_MS = 600_000

/** Signs in stderr that yt-dlp itself is out of date rather than the track being unavailable. */
export const EXTRACTOR_FAILURE = /Unable to extract|Signature extraction failed|nsig extraction failed|Requested format is not available|Sign in to confirm|HTTP Error 403|Precondition check failed|player response|Failed to parse JSON|challenge solver|js runtime/i

export function baseArgs(o: YtDlpOptions): string[] {
  const args = ['--no-warnings', '--no-playlist', '--no-remote-components', '--retries', '3', '--socket-timeout', '20', '--ffmpeg-location', o.paths.ffmpeg]
  if (o.paths.deno) args.push('--js-runtimes', `deno:${o.paths.deno}`)
  if (o.sleepRequests > 0) args.push('--sleep-requests', String(o.sleepRequests))
  return args
}

/** Sanitise a search query the way the Python did: strip control characters, cap length. */
export function cleanQuery(q: string): string {
  // eslint-disable-next-line no-control-regex
  return q.replace(/[\x00-\x1f]/g, ' ').trim().slice(0, 200)
}

const PRINT = '%(id)s\t%(title)s\t%(channel,uploader)s\t%(duration)s'

export function parsePrintLines(stdout: string): ResolvedUpload[] {
  const out: ResolvedUpload[] = []
  for (const line of stdout.split(/\r?\n/)) {
    const [id, title, channel, duration] = line.split('\t')
    if (!id || !YT_ID.test(id.trim())) continue
    const d = Number(duration)
    out.push({ videoId: id.trim(), url: `https://www.youtube.com/watch?v=${id.trim()}`, title: (title ?? '').trim(), channel: (channel ?? '').replace(/^NA$/, '').trim(), duration: Number.isFinite(d) && d > 0 ? d : null })
  }
  return out
}

/** "artist title" → the first of the top search results that is not rejected. */
export async function resolveSearch(o: YtDlpOptions, query: string, rejected: string[]): Promise<ResolvedUpload | undefined> {
  const q = cleanQuery(query)
  if (!q) return undefined
  const n = Math.min(10, 3 + rejected.length)
  const res = await runTool(o.paths.ytdlp, [...baseArgs(o), '--skip-download', '--flat-playlist', '--print', PRINT, '--', `ytsearch${n}:${q}`], { timeoutMs: SEARCH_TIMEOUT_MS })
  if (res.code !== 0) {
    const tail = lastLine(res.stderr)
    o.log?.(`  · search ${JSON.stringify(q)} failed: ${tail}`)
    if (EXTRACTOR_FAILURE.test(res.stderr)) o.onExtractorFailure?.(tail)
    return undefined
  }
  const found = parsePrintLines(res.stdout).filter((u) => !rejected.includes(u.videoId))
  if (!found.length) o.log?.(`  · search ${JSON.stringify(q)} found nothing new`)
  return found[0]
}

/** Title, channel and duration for a known URL, without downloading. */
export async function inspect(o: YtDlpOptions, url: string): Promise<ResolvedUpload | undefined> {
  const res = await runTool(o.paths.ytdlp, [...baseArgs(o), '--skip-download', '--print', PRINT, '--', url], { timeoutMs: SEARCH_TIMEOUT_MS })
  if (res.code !== 0) {
    if (EXTRACTOR_FAILURE.test(res.stderr)) o.onExtractorFailure?.(lastLine(res.stderr))
    return undefined
  }
  return parsePrintLines(res.stdout)[0]
}

/** Best audio into workdir/src.<ext>, with the info JSON (heatmap, duration) alongside. One attempt; no cookies. */
export async function downloadAudio(o: YtDlpOptions, url: string, workdir: string, timeoutMs = DOWNLOAD_TIMEOUT_MS): Promise<DownloadedSource | undefined> {
  await fs.mkdir(workdir, { recursive: true })
  const out = join(workdir, 'src.%(ext)s')
  const res = await runTool(o.paths.ytdlp, [...baseArgs(o), '-f', 'bestaudio', '--write-info-json', '-o', out, '--', url], { timeoutMs })
  const files = (await fs.readdir(workdir)).filter((f) => f.startsWith('src.') && !f.endsWith('.json')).sort()
  if (res.code !== 0 || !files.length) {
    const tail = lastLine(res.stderr)
    o.log?.(`  · download failed: ${tail}`)
    if (EXTRACTOR_FAILURE.test(res.stderr)) o.onExtractorFailure?.(tail)
    return undefined
  }
  let info: DownloadedSource['info']
  const infoFile = (await fs.readdir(workdir)).find((f) => f.endsWith('.info.json'))
  if (infoFile) {
    try {
      info = JSON.parse(await fs.readFile(join(workdir, infoFile), 'utf8')) as DownloadedSource['info']
    } catch {
      info = undefined
    }
  }
  return { path: join(workdir, files[0]!), info }
}

/** The whole track for promotion. */
export async function downloadFull(o: YtDlpOptions, url: string, workdir: string): Promise<{ path: string } | undefined> {
  await fs.mkdir(workdir, { recursive: true })
  const out = join(workdir, 'full.%(ext)s')
  const res = await runTool(o.paths.ytdlp, [...baseArgs(o), '-f', 'bestaudio', '-o', out, '--', url], { timeoutMs: FULL_TIMEOUT_MS })
  const files = (await fs.readdir(workdir)).filter((f) => f.startsWith('full.')).sort()
  if (res.code !== 0 || !files.length) {
    const tail = lastLine(res.stderr)
    o.log?.(`  · full download failed: ${tail}`)
    if (EXTRACTOR_FAILURE.test(res.stderr)) o.onExtractorFailure?.(tail)
    return undefined
  }
  return { path: join(workdir, files[0]!) }
}

/** "yt-dlp --version" → "2026.08.19", or undefined if it does not run. */
export async function version(ytdlp: string): Promise<string | undefined> {
  const res = await runTool(ytdlp, ['--version'], { timeoutMs: 30_000 })
  const v = res.stdout.trim().split(/\s+/)[0]
  return res.code === 0 && v ? v : undefined
}
