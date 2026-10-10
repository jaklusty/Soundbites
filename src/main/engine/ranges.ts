/**
 * HTTP range handling for the soundbites:// audio protocol. The sandboxed page cannot read the
 * library folder, so the main process serves clips and full tracks itself, and answers byte-range
 * requests so scrubbing works. Pure functions here; the Electron glue is in protocol.ts.
 */
import { basename, join, resolve, sep } from 'node:path'

export interface RangeSpec {
  start: number
  end: number
}

/** Parse "bytes=a-b" / "bytes=a-" / "bytes=-n" against a file size. undefined = whole file; null = unsatisfiable. */
export function parseRange(header: string | null | undefined, size: number): RangeSpec | undefined | null {
  if (!header) return undefined
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim())
  if (!m) return undefined
  const [, a, b] = m
  if (a === '' && b === '') return undefined
  let start: number
  let end: number
  if (a === '') {
    const suffix = Number(b)
    if (suffix === 0) return null
    start = Math.max(0, size - suffix)
    end = size - 1
  } else {
    start = Number(a)
    end = b === '' ? size - 1 : Math.min(Number(b), size - 1)
  }
  if (start >= size || start > end) return null
  return { start, end }
}

/**
 * Map a soundbites:// URL to a file inside the library, or undefined. Only clips/<id>.mp3 and
 * full/<id>/<file> are reachable, and only with plain safe names, so nothing can escape the
 * library folder (hard requirement 6).
 */
export function resolveMediaPath(libraryRoot: string, url: string): string | undefined {
  let u: URL
  try {
    u = new URL(url)
  } catch {
    return undefined
  }
  if (u.protocol !== 'soundbites:') return undefined
  const parts = decodeURIComponent(u.pathname).split('/').filter(Boolean)
  const host = u.hostname
  const SAFE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$/
  let rel: string[]
  if (host === 'clip' && parts.length === 1 && SAFE.test(parts[0]!) && parts[0]!.endsWith('.mp3')) {
    rel = ['clips', parts[0]!]
  } else if (host === 'full' && parts.length === 2 && SAFE.test(parts[0]!) && SAFE.test(parts[1]!)) {
    rel = ['full', parts[0]!, parts[1]!]
  } else {
    return undefined
  }
  if (rel.some((p) => p === '..' || p === '.' || p !== basename(p))) return undefined
  const full = resolve(join(libraryRoot, ...rel))
  const root = resolve(libraryRoot)
  if (full !== root && !full.startsWith(root + sep)) return undefined
  return full
}

export function mediaUrlForClip(clipRel: string): string {
  return `soundbites://clip/${encodeURIComponent(basename(clipRel))}`
}

export function mediaUrlForFull(fullRel: string): string {
  const parts = fullRel.split(/[\\/]/).filter(Boolean)
  const id = parts[parts.length - 2] ?? ''
  const file = parts[parts.length - 1] ?? ''
  return `soundbites://full/${encodeURIComponent(id)}/${encodeURIComponent(file)}`
}

export function mimeFor(path: string): string {
  const ext = path.toLowerCase().slice(path.lastIndexOf('.'))
  return (
    {
      '.mp3': 'audio/mpeg',
      '.wav': 'audio/wav',
      '.m4a': 'audio/mp4',
      '.webm': 'audio/webm',
      '.opus': 'audio/ogg',
      '.ogg': 'audio/ogg',
      '.flac': 'audio/flac'
    }[ext] ?? 'application/octet-stream'
  )
}
