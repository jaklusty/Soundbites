/**
 * Safe JSON storage for the library folder. Port of the rules in libstore.py, adjusted where the
 * build brief says so:
 *
 *  - every write goes to a temporary file in the same folder, is flushed to disk, then renamed
 *    over the target (atomic on both macOS and Windows);
 *  - before the rename, the previous good copy becomes <name>.bak;
 *  - a lock around every write so two operations never write at once (directory-based lock via
 *    proper-lockfile, because Windows has no flock);
 *  - a corrupt file is first copied aside as <name>.corrupt-<timestamp> (never deleted), then
 *    restored from .bak and reported as a health event. With no usable backup nothing is
 *    changed and the caller gets an error. (The Python claims to leave the damaged file in place
 *    but actually overwrites it; this version keeps the copy.)
 *  - replacing a file on Windows can fail while antivirus has it open: rename is retried for a
 *    few seconds before giving up.
 */
import { promises as fs } from 'node:fs'
import { createHash, randomBytes } from 'node:crypto'
import { join, dirname, basename } from 'node:path'
import lockfile from 'proper-lockfile'

export type HealthLevel = 'info' | 'warning' | 'error'

export interface HealthEvent {
  level: HealthLevel
  /** Short, user-facing, one line. Never mentions Python, Claude or a server. */
  message: string
  /** Which state file this is about, e.g. "library.json". */
  file?: string
  at: string
}

export type HealthListener = (event: HealthEvent) => void

export class StoreError extends Error {
  constructor(
    message: string,
    readonly code: 'corrupt-no-backup' | 'locked' | 'io' | 'missing',
    readonly file?: string
  ) {
    super(message)
    this.name = 'StoreError'
  }
}

export interface ReadResult<T> {
  data: T
  /** True when the file was restored from .bak during this read. */
  recovered: boolean
}

export interface StoreOptions {
  /** JSON indentation. The existing library files are written by Python with indent=2. */
  indent?: number
  /** Milliseconds to keep retrying a rename that fails with a Windows sharing violation. */
  renameRetryMs?: number
  /** Lock settings. `stale` is how old a lock may be before it is considered abandoned. */
  lock?: { staleMs?: number; retries?: number }
  onHealth?: HealthListener
  /** Injectable clock for tests. */
  now?: () => Date
}

const RETRYABLE_RENAME = new Set(['EPERM', 'EBUSY', 'EACCES', 'ENOTEMPTY'])

function timestampForFilename(d: Date): string {
  // 2026-10-10T17-05-33 (colons are not allowed in Windows file names)
  return d.toISOString().replace(/\.\d{3}Z$/, '').replace(/:/g, '-')
}

async function exists(p: string): Promise<boolean> {
  try {
    await fs.access(p)
    return true
  } catch {
    return false
  }
}

async function sleep(ms: number): Promise<void> {
  await new Promise((r) => setTimeout(r, ms))
}

export class Store {
  readonly root: string
  private readonly indent: number
  private readonly renameRetryMs: number
  private readonly staleMs: number
  private readonly retries: number
  private readonly listeners: HealthListener[] = []
  private readonly now: () => Date

  constructor(root: string, options: StoreOptions = {}) {
    this.root = root
    this.indent = options.indent ?? 2
    this.renameRetryMs = options.renameRetryMs ?? 3000
    this.staleMs = options.lock?.staleMs ?? 15000
    this.retries = options.lock?.retries ?? 40
    this.now = options.now ?? (() => new Date())
    if (options.onHealth) this.listeners.push(options.onHealth)
  }

  onHealth(listener: HealthListener): () => void {
    this.listeners.push(listener)
    return () => {
      const i = this.listeners.indexOf(listener)
      if (i >= 0) this.listeners.splice(i, 1)
    }
  }

  private emit(level: HealthLevel, message: string, file?: string): void {
    const event: HealthEvent = { level, message, file, at: this.now().toISOString() }
    for (const l of this.listeners) l(event)
  }

  path(name: string): string {
    if (name !== basename(name)) throw new StoreError(`Not a plain file name: ${name}`, 'io', name)
    return join(this.root, name)
  }

  /** Serialise the way the Python did: 2-space indent, non-ASCII kept as is, trailing newline. */
  serialize(data: unknown): string {
    return JSON.stringify(data, null, this.indent) + '\n'
  }

  /**
   * Read and parse a JSON state file. Returns `undefined` data when the file does not exist.
   * On corruption: copy aside, restore from .bak, report. Without a usable .bak: throw and
   * change nothing (except the copy aside, which is additive).
   */
  async read<T = unknown>(name: string): Promise<ReadResult<T | undefined>> {
    const target = this.path(name)
    let raw: string
    try {
      raw = await fs.readFile(target, 'utf8')
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return { data: undefined, recovered: false }
      throw new StoreError(`Could not read ${name}: ${(err as Error).message}`, 'io', name)
    }

    try {
      return { data: JSON.parse(raw) as T, recovered: false }
    } catch {
      /* fall through to recovery */
    }

    const corruptCopy = `${target}.corrupt-${timestampForFilename(this.now())}`
    await fs.copyFile(target, corruptCopy)

    const backup = `${target}.bak`
    let restored: T | undefined
    try {
      restored = JSON.parse(await fs.readFile(backup, 'utf8')) as T
    } catch {
      this.emit(
        'error',
        `${name} is damaged and there is no usable backup. A copy was saved as ${basename(corruptCopy)}. Nothing has been changed.`,
        name
      )
      throw new StoreError(`${name} is corrupt and ${basename(backup)} is unusable`, 'corrupt-no-backup', name)
    }

    // Restore the backup over the damaged file (the damaged copy is kept alongside).
    await this.writeAtomic(target, this.serialize(restored), { keepBackup: false })
    this.emit(
      'warning',
      `${name} was damaged and has been restored from its backup. The damaged copy was kept as ${basename(corruptCopy)}.`,
      name
    )
    return { data: restored, recovered: true }
  }

  /** Read a file that must exist and parse, applying a default when it does not exist. */
  async readOr<T>(name: string, fallback: T): Promise<T> {
    const r = await this.read<T>(name)
    return r.data === undefined ? fallback : r.data
  }

  /** Write a JSON state file safely, under the folder lock. */
  async write(name: string, data: unknown): Promise<void> {
    await this.withLock(() => this.writeUnlocked(name, data))
  }

  /** Write without taking the lock. Only call inside `withLock`. */
  async writeUnlocked(name: string, data: unknown): Promise<void> {
    await this.writeAtomic(this.path(name), this.serialize(data), { keepBackup: true })
  }

  /**
   * Read-modify-write under one lock. `fn` receives the current value (or `fallback`) and returns
   * the new value to store. Returning `undefined` leaves the file untouched.
   */
  async update<T>(name: string, fallback: T, fn: (current: T) => T | undefined | Promise<T | undefined>): Promise<T> {
    return this.withLock(async () => {
      const current = await this.readOr<T>(name, fallback)
      const next = await fn(current)
      if (next === undefined) return current
      await this.writeUnlocked(name, next)
      return next
    })
  }

  /** Run `fn` while holding the library write lock. Re-entrant calls are not supported. */
  async withLock<T>(fn: () => Promise<T>): Promise<T> {
    await fs.mkdir(this.root, { recursive: true })
    const lockTarget = join(this.root, '.write')
    let release: () => Promise<void>
    try {
      release = await lockfile.lock(lockTarget, {
        realpath: false,
        stale: this.staleMs,
        update: Math.max(1000, Math.floor(this.staleMs / 3)),
        retries: { retries: this.retries, minTimeout: 50, maxTimeout: 400 }
      })
    } catch (err) {
      throw new StoreError(`Another operation is writing to the library: ${(err as Error).message}`, 'locked')
    }
    try {
      return await fn()
    } finally {
      await release().catch(() => undefined)
    }
  }

  private async writeAtomic(target: string, content: string, opts: { keepBackup: boolean }): Promise<void> {
    const dir = dirname(target)
    await fs.mkdir(dir, { recursive: true })
    const tmp = join(dir, `.${basename(target)}.tmp-${process.pid}-${randomBytes(4).toString('hex')}`)
    const handle = await fs.open(tmp, 'w')
    try {
      await handle.writeFile(content, 'utf8')
      await handle.sync()
    } finally {
      await handle.close()
    }

    if (opts.keepBackup && (await exists(target))) {
      // Only a parseable file becomes the backup; never replace a good .bak with a bad one.
      try {
        JSON.parse(await fs.readFile(target, 'utf8'))
        await fs.copyFile(target, `${target}.bak`)
      } catch {
        /* leave the existing .bak alone */
      }
    }

    await this.renameWithRetry(tmp, target)
  }

  private async renameWithRetry(from: string, to: string): Promise<void> {
    const deadline = Date.now() + this.renameRetryMs
    let delay = 50
    for (;;) {
      try {
        await fs.rename(from, to)
        return
      } catch (err) {
        const code = (err as NodeJS.ErrnoException).code ?? ''
        if (!RETRYABLE_RENAME.has(code) || Date.now() >= deadline) {
          await fs.rm(from, { force: true }).catch(() => undefined)
          throw new StoreError(
            `Could not replace ${basename(to)}. Another program may have it open. (${code || (err as Error).message})`,
            'io',
            basename(to)
          )
        }
        await sleep(delay)
        delay = Math.min(delay * 2, 500)
      }
    }
  }
}

/** Stable content hash, used by tests to compare library files apart from timestamps. */
export function contentHash(text: string): string {
  return createHash('sha256').update(text).digest('hex')
}
