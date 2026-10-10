/**
 * Keeps yt-dlp and Deno installed in the app-data folder and up to date: first run, weekly, once
 * after an extractor failure, and again if a file goes missing (antivirus sometimes removes it).
 * Downloads go to versioned file names and switch over only after the checksum passes.
 */
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { installLatest, pickInstalled, toolSpec, ToolDownloadError, type Platform, type FetchLike } from './tools'
import { extractZipEntry } from './zip'

export interface ToolPaths {
  ytdlp?: string
  deno?: string
}

export interface ToolManagerOptions {
  toolsDir: string
  platform: Platform
  arch: 'arm64' | 'x64'
  fetchImpl?: FetchLike
  log?: (line: string) => void
}

export const WEEK_MS = 7 * 24 * 3600 * 1000

export class ToolManager {
  private readonly dir: string
  private readonly platform: Platform
  private readonly arch: 'arm64' | 'x64'
  private readonly fetchImpl: FetchLike
  private readonly log: (line: string) => void
  private installing: Promise<ToolPaths> | undefined
  lastMessage: string | undefined

  constructor(opts: ToolManagerOptions) {
    this.dir = opts.toolsDir
    this.platform = opts.platform
    this.arch = opts.arch
    this.fetchImpl = opts.fetchImpl ?? (fetch as unknown as FetchLike)
    this.log = opts.log ?? (() => undefined)
  }

  /** What is on disk right now (newest build of each), without touching the network. */
  async installed(): Promise<ToolPaths> {
    const files = await fs.readdir(this.dir).catch(() => [] as string[])
    const y = pickInstalled(files, toolSpec('yt-dlp', this.platform, this.arch), this.platform)
    const d = pickInstalled(files, toolSpec('deno', this.platform, this.arch), this.platform)
    return { ytdlp: y ? join(this.dir, y) : undefined, deno: d ? join(this.dir, d) : undefined }
  }

  versions(paths: ToolPaths): { ytdlp?: string; deno?: string } {
    const tag = (p: string | undefined, base: string) => (p ? p.split(/[\\/]/).pop()!.replace(new RegExp(`^${base}-`), '').replace(/\.exe$/, '') : undefined)
    return { ytdlp: tag(paths.ytdlp, 'yt-dlp'), deno: tag(paths.deno, 'deno') }
  }

  /**
   * Make sure both tools exist, downloading what is missing. With `checkForNewer`, also look for
   * a newer release of each (the weekly / after-failure check). Never throws: returns what is
   * usable and sets lastMessage for Needs attention.
   */
  async ensure(checkForNewer: boolean): Promise<ToolPaths> {
    if (this.installing) return this.installing
    this.installing = this.doEnsure(checkForNewer).finally(() => {
      this.installing = undefined
    })
    return this.installing
  }

  private async doEnsure(checkForNewer: boolean): Promise<ToolPaths> {
    await fs.mkdir(this.dir, { recursive: true })
    const have = await this.installed()
    const problems: string[] = []
    for (const name of ['yt-dlp', 'deno'] as const) {
      const current = name === 'yt-dlp' ? have.ytdlp : have.deno
      if (current && !checkForNewer) continue
      try {
        const r = await installLatest(toolSpec(name, this.platform, this.arch), this.platform, this.dir, this.fetchImpl, extractZipEntry)
        if (!r.alreadyPresent) this.log(`${name} ${r.tag} installed`)
        if (name === 'yt-dlp') have.ytdlp = r.path
        else have.deno = r.path
      } catch (err) {
        const e = err as ToolDownloadError
        if (!current) problems.push(`${name} could not be downloaded (${e.message}). Downloads need it; it will be tried again.`)
        else this.log(`${name}: update check failed (${e.message}); keeping ${current}`)
      }
    }
    await this.pruneOld(have)
    this.lastMessage = problems.length ? problems.join(' ') : undefined
    return have
  }

  /** A tool file that has disappeared (antivirus) is reported and re-downloaded by the caller. */
  async verifyPresent(paths: ToolPaths): Promise<string | undefined> {
    for (const [name, p] of [['yt-dlp', paths.ytdlp], ['Deno', paths.deno]] as const) {
      if (p && !(await fs.stat(p).catch(() => undefined))) return `${name} has gone missing from ${this.dir} (antivirus sometimes removes it). It will be downloaded again.`
    }
    return undefined
  }

  /** Keep only the newest build of each tool, plus the one currently in use. Windows cannot delete a running .exe, so failures are ignored. */
  private async pruneOld(keep: ToolPaths): Promise<void> {
    const files = await fs.readdir(this.dir).catch(() => [] as string[])
    const keepNames = new Set([keep.ytdlp, keep.deno].filter(Boolean).map((p) => p!.split(/[\\/]/).pop()!))
    for (const f of files) {
      if (keepNames.has(f) || f.endsWith('.part') || f.endsWith('.extracting')) continue
      if (/^(yt-dlp|deno)-/.test(f)) await fs.rm(join(this.dir, f), { force: true }).catch(() => undefined)
    }
  }
}
