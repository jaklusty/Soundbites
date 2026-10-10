/**
 * yt-dlp and Deno are not bundled. This module downloads the official standalone builds into the
 * app-data folder, verifies them against the publisher's checksums, keeps them under versioned
 * file names (so a running yt-dlp.exe is never overwritten on Windows), and tells the caller
 * which one to run.
 *
 * Only the pure, testable parts live here: checksum parsing, release-tag detection, file naming
 * and the verify step. The download itself takes a `fetch` so tests can hand in a fake.
 */
import { createHash } from 'node:crypto'
import { createReadStream, promises as fs } from 'node:fs'
import { basename, join } from 'node:path'
import { pipeline } from 'node:stream/promises'
import { Writable } from 'node:stream'

export type Platform = 'darwin' | 'win32'
export type ToolName = 'yt-dlp' | 'deno'

export interface ToolSpec {
  name: ToolName
  /** The GitHub repo whose latest release we follow. */
  repo: string
  /** Release asset name for this platform/arch. */
  asset: string
  /** Checksum file name for this platform/arch, or undefined when the asset list is a single file. */
  sums: string
  /** Name inside the zip, if the asset is a zip. */
  zipEntry?: string
  /** What the installed file is called before the version suffix. */
  localBase: string
}

export function toolSpec(name: ToolName, platform: Platform, arch: 'arm64' | 'x64'): ToolSpec {
  if (name === 'yt-dlp') {
    return platform === 'darwin'
      ? { name, repo: 'yt-dlp/yt-dlp', asset: 'yt-dlp_macos', sums: 'SHA2-256SUMS', localBase: 'yt-dlp' }
      : { name, repo: 'yt-dlp/yt-dlp', asset: 'yt-dlp.exe', sums: 'SHA2-256SUMS', localBase: 'yt-dlp' }
  }
  // Deno publishes one zip per target with a matching .sha256sum file next to it.
  const target =
    platform === 'darwin'
      ? arch === 'arm64'
        ? 'aarch64-apple-darwin'
        : 'x86_64-apple-darwin'
      : 'x86_64-pc-windows-msvc'
  const asset = `deno-${target}.zip`
  return {
    name,
    repo: 'denoland/deno',
    asset,
    sums: `${asset}.sha256sum`,
    zipEntry: platform === 'win32' ? 'deno.exe' : 'deno',
    localBase: 'deno'
  }
}

export function latestDownloadUrl(spec: ToolSpec, file: string): string {
  return `https://github.com/${spec.repo}/releases/latest/download/${file}`
}

/**
 * Parse a checksum file into {fileName: lowercaseHexHash}. Handles both layouts we meet:
 *   GNU style:          "<hash>  <name>" one per line (yt-dlp's SHA2-256SUMS, Deno on macOS)
 *   PowerShell style:   "Algorithm : SHA256 / Hash : <HEX> / Path : C:\...\<name>" (Deno on Windows)
 */
export function parseChecksums(text: string): Map<string, string> {
  const out = new Map<string, string>()
  const lines = text.split(/\r?\n/)

  // PowerShell Get-FileHash layout
  let psHash: string | undefined
  for (const line of lines) {
    const m = /^\s*(Algorithm|Hash|Path)\s*:\s*(.+?)\s*$/.exec(line)
    if (!m) continue
    if (m[1] === 'Hash') psHash = m[2]!.toLowerCase()
    if (m[1] === 'Path' && psHash) {
      const name = m[2]!.split(/[\\/]/).pop()!
      out.set(name, psHash)
      psHash = undefined
    }
  }

  // GNU layout (also "hash *name" for binary mode)
  for (const line of lines) {
    const m = /^([0-9a-fA-F]{64})\s+\*?(\S.*?)\s*$/.exec(line)
    if (m) out.set(m[2]!, m[1]!.toLowerCase())
  }
  return out
}

export async function sha256File(path: string): Promise<string> {
  const hash = createHash('sha256')
  await pipeline(
    createReadStream(path),
    new Writable({
      write(chunk, _enc, cb) {
        hash.update(chunk)
        cb()
      }
    })
  )
  return hash.digest('hex')
}

/** The release tag from a resolved GitHub download URL, e.g. ".../releases/download/2026.08.19/yt-dlp_macos" → "2026.08.19". */
export function tagFromDownloadUrl(url: string): string | undefined {
  const m = /\/releases\/download\/([^/]+)\//.exec(url)
  return m ? decodeURIComponent(m[1]!) : undefined
}

/** Versioned local file name: yt-dlp-2026.08.19, yt-dlp-2026.08.19.exe, deno-v2.9.7 ... */
export function versionedFileName(spec: ToolSpec, tag: string, platform: Platform): string {
  const safeTag = tag.replace(/[^0-9A-Za-z._-]/g, '_')
  return `${spec.localBase}-${safeTag}${platform === 'win32' ? '.exe' : ''}`
}

/** Pick the newest installed build of a tool from the files in the tools folder. */
export function pickInstalled(files: string[], spec: ToolSpec, platform: Platform): string | undefined {
  const suffix = platform === 'win32' ? '.exe' : ''
  const re = new RegExp(`^${spec.localBase}-(.+?)${suffix.replace('.', '\\.')}$`)
  const tagged = files
    .map((f) => ({ f, m: re.exec(f) }))
    .filter((x) => x.m && !x.f.endsWith('.part'))
    .map((x) => ({ f: x.f, tag: x.m![1]! }))
  if (tagged.length === 0) return undefined
  tagged.sort((a, b) => compareTags(b.tag, a.tag))
  return tagged[0]!.f
}

/** Compare release tags like "2026.08.19" / "v2.9.7" numerically segment by segment. */
export function compareTags(a: string, b: string): number {
  const pa = a.replace(/^v/, '').split(/[^0-9]+/).filter(Boolean).map(Number)
  const pb = b.replace(/^v/, '').split(/[^0-9]+/).filter(Boolean).map(Number)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0)
    if (d !== 0) return d
  }
  return 0
}

export interface FetchLike {
  (url: string, init?: { redirect?: 'follow' | 'manual' }): Promise<{
    ok: boolean
    status: number
    url: string
    headers: { get(name: string): string | null }
    text(): Promise<string>
    body: ReadableStream<Uint8Array> | null
  }>
}

export class ToolDownloadError extends Error {
  constructor(
    message: string,
    readonly code: 'network' | 'checksum-missing' | 'checksum-mismatch' | 'no-tag' | 'zip'
  ) {
    super(message)
    this.name = 'ToolDownloadError'
  }
}

/**
 * Download the latest release of a tool into `toolsDir`, verify it and install it under a
 * versioned name. Returns the absolute path of the installed executable. Never touches an
 * existing file of the same version (so a running .exe is never replaced), and only switches
 * callers over once the checksum has passed. `extractZipEntry` is injected because zip handling
 * lives with the Electron-side code.
 */
export async function installLatest(
  spec: ToolSpec,
  platform: Platform,
  toolsDir: string,
  fetchImpl: FetchLike,
  extractZipEntry?: (zipPath: string, entry: string, dest: string) => Promise<void>
): Promise<{ path: string; tag: string; alreadyPresent: boolean }> {
  await fs.mkdir(toolsDir, { recursive: true })

  // 1. Resolve the tag: follow the redirect of the "latest" URL and read the tag from it.
  const sumsRes = await fetchImpl(latestDownloadUrl(spec, spec.sums), { redirect: 'follow' })
  if (!sumsRes.ok) throw new ToolDownloadError(`Could not fetch checksums for ${spec.name} (HTTP ${sumsRes.status})`, 'network')
  const tag = tagFromDownloadUrl(sumsRes.url)
  if (!tag) throw new ToolDownloadError(`Could not tell which ${spec.name} version is current`, 'no-tag')
  const sums = parseChecksums(await sumsRes.text())
  const expected = sums.get(spec.asset)
  if (!expected) throw new ToolDownloadError(`Checksum list for ${spec.name} does not mention ${spec.asset}`, 'checksum-missing')

  const finalName = versionedFileName(spec, tag, platform)
  const finalPath = join(toolsDir, finalName)
  if (await fileExists(finalPath)) return { path: finalPath, tag, alreadyPresent: true }

  // 2. Download the asset for that exact tag to a .part file.
  const assetUrl = `https://github.com/${spec.repo}/releases/download/${encodeURIComponent(tag)}/${spec.asset}`
  const part = join(toolsDir, `${spec.asset}-${tag}.part`)
  const res = await fetchImpl(assetUrl, { redirect: 'follow' })
  if (!res.ok || !res.body) throw new ToolDownloadError(`Could not download ${spec.asset} (HTTP ${res.status})`, 'network')
  await fs.rm(part, { force: true })
  const handle = await fs.open(part, 'w')
  try {
    const reader = res.body.getReader()
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      if (value) await handle.write(value)
    }
    await handle.sync()
  } finally {
    await handle.close()
  }

  // 3. Verify before anything is renamed into place.
  const actual = await sha256File(part)
  if (actual !== expected) {
    await fs.rm(part, { force: true })
    throw new ToolDownloadError(`${spec.asset} did not match its published checksum and was discarded`, 'checksum-mismatch')
  }

  // 4. Install: unzip the single entry, or rename the binary. Mark executable on macOS.
  if (spec.zipEntry) {
    if (!extractZipEntry) throw new ToolDownloadError('No zip extractor available', 'zip')
    const tmpOut = `${finalPath}.extracting`
    await fs.rm(tmpOut, { force: true })
    await extractZipEntry(part, spec.zipEntry, tmpOut)
    await fs.rename(tmpOut, finalPath)
    await fs.rm(part, { force: true })
  } else {
    await fs.rename(part, finalPath)
  }
  if (platform !== 'win32') await fs.chmod(finalPath, 0o755)
  return { path: finalPath, tag, alreadyPresent: false }
}

async function fileExists(p: string): Promise<boolean> {
  try {
    await fs.access(p)
    return true
  } catch {
    return false
  }
}

/** Base name helper exported for the Needs-attention wording ("yt-dlp-2026.08.19 has gone missing"). */
export function displayName(path: string): string {
  return basename(path)
}
