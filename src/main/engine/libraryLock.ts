/**
 * The library-folder lock (hard requirement 9, second half). One app instance per machine is
 * handled by Electron's single-instance lock; this stops a second computer or user account from
 * writing to the same library folder, and detects a lock left behind by a crash so it can be
 * offered for take-over instead of blocking the user.
 *
 * Design: a directory `soundbites.lock` inside the library folder (mkdir is atomic on every file
 * system we care about) containing `owner.json` with who holds it and a heartbeat timestamp that
 * is refreshed every `heartbeatMs`. A lock whose heartbeat is older than `staleAfterMs` is
 * reported as stale. The caller decides whether to take it over.
 */
import { promises as fs } from 'node:fs'
import { hostname, userInfo } from 'node:os'
import { join } from 'node:path'

export interface LockOwner {
  host: string
  user: string
  pid: number
  app: string
  started: string
  heartbeat: string
}

export type AcquireResult =
  | { status: 'acquired' }
  | { status: 'held'; owner: LockOwner }
  | { status: 'stale'; owner: LockOwner | undefined }

export interface LibraryLockOptions {
  heartbeatMs?: number
  staleAfterMs?: number
  appLabel?: string
  now?: () => Date
}

export const LOCK_DIR_NAME = 'soundbites.lock'

export class LibraryLock {
  private readonly dir: string
  private readonly ownerFile: string
  private readonly heartbeatMs: number
  private readonly staleAfterMs: number
  private readonly appLabel: string
  private readonly now: () => Date
  private timer: NodeJS.Timeout | undefined
  private held = false

  constructor(libraryRoot: string, options: LibraryLockOptions = {}) {
    this.dir = join(libraryRoot, LOCK_DIR_NAME)
    this.ownerFile = join(this.dir, 'owner.json')
    this.heartbeatMs = options.heartbeatMs ?? 15000
    this.staleAfterMs = options.staleAfterMs ?? 60000
    this.appLabel = options.appLabel ?? 'Soundbites'
    this.now = options.now ?? (() => new Date())
  }

  get isHeld(): boolean {
    return this.held
  }

  private ownerRecord(started: string): LockOwner {
    let user = 'unknown'
    try {
      user = userInfo().username
    } catch {
      /* some locked-down accounts throw */
    }
    return {
      host: hostname(),
      user,
      pid: process.pid,
      app: this.appLabel,
      started,
      heartbeat: this.now().toISOString()
    }
  }

  async readOwner(): Promise<LockOwner | undefined> {
    try {
      return JSON.parse(await fs.readFile(this.ownerFile, 'utf8')) as LockOwner
    } catch {
      return undefined
    }
  }

  /** Try to take the lock. Never removes someone else's lock; reports `stale` instead. */
  async acquire(): Promise<AcquireResult> {
    try {
      await fs.mkdir(this.dir)
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'EEXIST') throw err
      const owner = await this.readOwner()
      if (owner && this.isFresh(owner)) return { status: 'held', owner }
      // No readable owner file, or a heartbeat older than staleAfterMs: left behind by a crash.
      return { status: 'stale', owner }
    }
    await this.writeOwner(this.ownerRecord(this.now().toISOString()))
    this.held = true
    this.startHeartbeat()
    return { status: 'acquired' }
  }

  /** Remove a stale lock and acquire. Only call after the user agreed to take over. */
  async takeOver(): Promise<AcquireResult> {
    await fs.rm(this.dir, { recursive: true, force: true })
    return this.acquire()
  }

  async release(): Promise<void> {
    this.stopHeartbeat()
    if (!this.held) return
    this.held = false
    await fs.rm(this.dir, { recursive: true, force: true }).catch(() => undefined)
  }

  /** Heartbeat age check. An owner file with an unparseable date counts as stale. */
  isFresh(owner: LockOwner): boolean {
    const t = Date.parse(owner.heartbeat)
    if (Number.isNaN(t)) return false
    return this.now().getTime() - t < this.staleAfterMs
  }

  /** Public for tests: write one heartbeat now. */
  async beat(): Promise<void> {
    const current = await this.readOwner()
    const started = current?.started ?? this.now().toISOString()
    await this.writeOwner(this.ownerRecord(started))
  }

  private async writeOwner(owner: LockOwner): Promise<void> {
    const tmp = `${this.ownerFile}.tmp`
    await fs.writeFile(tmp, JSON.stringify(owner, null, 2))
    await fs.rename(tmp, this.ownerFile)
  }

  private startHeartbeat(): void {
    this.stopHeartbeat()
    this.timer = setInterval(() => {
      void this.beat().catch(() => undefined)
    }, this.heartbeatMs)
    this.timer.unref()
  }

  private stopHeartbeat(): void {
    if (this.timer) clearInterval(this.timer)
    this.timer = undefined
  }
}
