/**
 * Shared types and small helpers for the library files (library.json version 1). Field names and
 * shapes are exactly what the Python wrote, so an existing library opens unchanged.
 */

export interface Track {
  id: string
  first_seen: string
  runs: string[]
  clip: string | null
  clip_present: boolean
  title?: string
  artist?: string
  platform?: string
  direction?: string
  uses?: number
  bpm?: number
  energy?: string
  mood?: string[]
  suits?: string
  profiles?: string[]
  licence?: string
  notes?: string
  source_url?: string
  last_seen?: string
  uses_history?: Record<string, number>
  clip_bytes?: number
  hook_at?: number
  hook_method?: string
  hook_detail?: string
  pinned?: boolean
  full?: string
  full_format?: string
  full_bytes?: number
  promoted_at?: string
  full_error?: string
  // New in v1: match transparency and corrections. Absent on tracks the Python wrote.
  match?: { video_id: string; title: string; channel: string; duration: number | null }
  match_status?: 'matched' | 'no-confident-match' | 'user-link'
  rejected_video_ids?: string[]
  user_source_url?: string
  [extra: string]: unknown
}

export interface Library {
  version: number
  tracks: Track[]
  last_run?: string
  updated?: string
  [extra: string]: unknown
}

export interface Favourites {
  ids: string[]
  starred_at?: Record<string, string>
  updated?: string
}

export interface Profile {
  retention?: { keep_runs?: number; note?: string }
  promote?: { format?: string; note?: string }
  views?: { active?: string; saved?: Record<string, { label?: string; description?: string; rule?: unknown }>; note?: string }
  [extra: string]: unknown
}

/** A candidate as it arrives from the feed or a dropped run file, before normalisation. */
export interface RawCandidate {
  title?: unknown
  artist?: unknown
  search?: unknown
  source_url?: unknown
  local?: unknown
  hook_start?: unknown
  platform?: unknown
  direction?: unknown
  uses?: unknown
  bpm?: unknown
  energy?: unknown
  mood?: unknown
  suits?: unknown
  profiles?: unknown
  licence?: unknown
  notes?: unknown
  pin?: unknown
  [extra: string]: unknown
}

export interface Candidate {
  title: string
  artist: string
  search?: string
  source_url?: string
  local?: string
  hook_start?: string | number
  platform?: string
  direction?: string
  uses?: number
  bpm?: number
  energy?: string
  mood?: string[]
  suits?: string
  profiles?: string[]
  licence?: string
  notes?: string
  pin?: boolean
}

export const EMPTY_LIBRARY = (): Library => ({ version: 1, tracks: [] })

/** Run stamps sort chronologically only if they really are dates. (libstore.valid_run_stamp) */
export function validRunStamp(value: unknown): value is string {
  if (typeof value !== 'string') return false
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value)
  if (!m) return false
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])]
  const date = new Date(Date.UTC(y, mo - 1, d))
  return date.getUTCFullYear() === y && date.getUTCMonth() === mo - 1 && date.getUTCDate() === d
}

/** Later of two stamps; keeps last_run monotonic. (libstore.newer_stamp) */
export function newerStamp(a: unknown, b: unknown): string | undefined {
  if (!validRunStamp(a)) return validRunStamp(b) ? b : undefined
  if (!validRunStamp(b)) return a
  return a >= b ? a : b
}

/** "0:20" / "1:05" / 95 → seconds. (ingest.parse_ts) */
export function parseTs(value: unknown): number {
  if (value === null || value === undefined) return 20
  if (typeof value === 'number') return Math.max(0, Math.trunc(value))
  const parts = String(value).trim().split(':')
  const nums = parts.map((p) => Number(p))
  if (nums.some((n) => Number.isNaN(n))) return 20
  let seconds = 0
  for (const n of nums) seconds = seconds * 60 + n
  return Math.max(0, Math.trunc(seconds))
}

/** http(s) only, and never something that could be read as an option. (libstore.safe_media_url) */
export function safeMediaUrl(url: unknown): string | undefined {
  const s = String(url ?? '').trim()
  if (!s || s.startsWith('-')) return undefined
  return /^https?:\/\//i.test(s) ? s : undefined
}

/** Hard requirement 6: a feed source_url is accepted only for youtube.com and youtu.be. */
export function youtubeUrlOnly(url: unknown): string | undefined {
  const s = safeMediaUrl(url)
  if (!s) return undefined
  try {
    const host = new URL(s).hostname.toLowerCase()
    const ok = host === 'youtu.be' || host === 'youtube.com' || host.endsWith('.youtube.com')
    return ok ? s : undefined
  } catch {
    return undefined
  }
}

export const YT_ID = /^[A-Za-z0-9_-]{11}$/

/** Extract the 11-character video id from a youtube.com or youtu.be link. */
export function youtubeVideoId(url: string): string | undefined {
  try {
    const u = new URL(url)
    const host = u.hostname.toLowerCase()
    let id: string | null = null
    if (host === 'youtu.be') id = u.pathname.slice(1).split('/')[0] ?? null
    else if (host === 'youtube.com' || host.endsWith('.youtube.com')) {
      id = u.searchParams.get('v')
      if (!id) {
        const m = /^\/(?:shorts|embed|live)\/([A-Za-z0-9_-]{11})/.exec(u.pathname)
        id = m ? m[1]! : null
      }
    }
    return id && YT_ID.test(id) ? id : undefined
  } catch {
    return undefined
  }
}

function asString(v: unknown): string | undefined {
  if (v === null || v === undefined) return undefined
  const s = String(v).trim()
  return s ? s : undefined
}

function asInt(v: unknown): number | undefined {
  if (typeof v === 'number' && Number.isFinite(v)) return Math.trunc(v)
  if (typeof v === 'string' && /^\s*\d+\s*$/.test(v)) return parseInt(v, 10)
  return undefined
}

/**
 * Normalise a candidate (hard requirement 3): `mood` becomes a list, `suits` becomes one string.
 * `source` says where it came from: feed candidates lose the local-only fields the brief lists
 * (`local`, `pin`, `profiles`, `hook_start`) and may only carry a YouTube `source_url`; a run file
 * the user dropped into pending/ keeps them.
 */
export function normalizeCandidate(raw: RawCandidate, source: 'feed' | 'pending'): Candidate | { rejected: string } {
  const title = asString(raw.title)
  const artist = asString(raw.artist) ?? ''
  if (!title) return { rejected: '(candidate with no title)' }

  const c: Candidate = { title, artist }
  const search = asString(raw.search)
  if (search) c.search = search

  const url = source === 'feed' ? youtubeUrlOnly(raw.source_url) : safeMediaUrl(raw.source_url)
  if (url) c.source_url = url

  for (const key of ['platform', 'direction', 'energy', 'licence', 'notes'] as const) {
    const s = asString(raw[key])
    if (s) c[key] = s
  }
  const uses = asInt(raw.uses)
  if (uses !== undefined) c.uses = uses
  const bpm = asInt(raw.bpm)
  if (bpm !== undefined) c.bpm = bpm

  if (Array.isArray(raw.mood)) {
    const m = raw.mood.map((x) => String(x).trim()).filter(Boolean)
    if (m.length) c.mood = m
  } else if (typeof raw.mood === 'string' && raw.mood.trim()) {
    c.mood = raw.mood
      .split(/[,;]/)
      .map((x) => x.trim())
      .filter(Boolean)
  }

  if (Array.isArray(raw.suits)) {
    const s = raw.suits.map((x) => String(x).trim()).filter(Boolean).join(' ')
    if (s) c.suits = s
  } else {
    const s = asString(raw.suits)
    if (s) c.suits = s
  }

  if (source === 'pending') {
    const local = asString(raw.local)
    if (local) c.local = local
    if (raw.hook_start !== null && raw.hook_start !== undefined && String(raw.hook_start).trim() !== '') {
      c.hook_start = typeof raw.hook_start === 'number' ? raw.hook_start : String(raw.hook_start)
    }
    if (Array.isArray(raw.profiles)) {
      const p = raw.profiles.map((x) => String(x).trim()).filter(Boolean)
      if (p.length) c.profiles = p
    }
    if (raw.pin) c.pin = true
  }
  return c
}
