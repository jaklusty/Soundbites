/**
 * App settings live in the OS app-data folder (not in the library), so the library folder stays
 * portable. Written with the same safe-write rules as the library files.
 */
import { Store } from './store'

export interface AppSettings {
  libraryPath?: string
  /** Feed base: an https address ending in / or a local folder path. */
  feedBase: string
  /** Simultaneous downloads, 1..3. */
  concurrency: number
  /** Milliseconds between requests to YouTube. */
  requestPauseMs: number
  window?: { x?: number; y?: number; width: number; height: number; maximized?: boolean }
  /** When tools were last checked for a newer release (ISO). */
  toolsCheckedAt?: string
  /** When the feed was last checked (ISO), for the status line. */
  feedCheckedAt?: string
  /** When the app last looked for a newer release (ISO). */
  updateCheckedAt?: string
}

export const DEFAULT_FEED_BASE = 'https://raw.githubusercontent.com/jaklusty/Audio-Trends/main/'

export const DEFAULT_SETTINGS: AppSettings = {
  feedBase: DEFAULT_FEED_BASE,
  concurrency: 1,
  requestPauseMs: 2000
}

export class Settings {
  private readonly store: Store
  private cache: AppSettings | undefined

  constructor(appDataDir: string) {
    this.store = new Store(appDataDir)
  }

  async load(): Promise<AppSettings> {
    let data: Partial<AppSettings> | undefined
    try {
      data = (await this.store.read<Partial<AppSettings>>('settings.json')).data
    } catch {
      data = undefined // a corrupt settings file with no backup: start from defaults, nothing precious here
    }
    this.cache = sanitize({ ...DEFAULT_SETTINGS, ...(data ?? {}) })
    return this.cache
  }

  get current(): AppSettings {
    return this.cache ?? { ...DEFAULT_SETTINGS }
  }

  async update(patch: Partial<AppSettings>): Promise<AppSettings> {
    const next = sanitize({ ...this.current, ...patch })
    await this.store.write('settings.json', next)
    this.cache = next
    return next
  }
}

export function sanitize(s: AppSettings): AppSettings {
  const out = { ...s }
  out.concurrency = Math.min(3, Math.max(1, Math.trunc(Number(out.concurrency) || 1)))
  out.requestPauseMs = Math.max(0, Math.trunc(Number(out.requestPauseMs) || 0))
  out.feedBase = normaliseFeedBase(out.feedBase)
  if (out.libraryPath !== undefined && typeof out.libraryPath !== 'string') delete out.libraryPath
  return out
}

/** An https URL gets a trailing slash; anything else is treated as a local folder path. */
export function normaliseFeedBase(value: unknown): string {
  const s = String(value ?? '').trim()
  if (!s) return DEFAULT_FEED_BASE
  if (/^https?:\/\//i.test(s)) return s.endsWith('/') ? s : `${s}/`
  return s
}

export function isHttpFeed(base: string): boolean {
  return /^https?:\/\//i.test(base)
}
