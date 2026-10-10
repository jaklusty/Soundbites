/**
 * Opening a library folder (hard requirement 2). Three outcomes:
 *   - it has a library.json: open it;
 *   - it exists but has no library.json: the caller must ask "Start a new library here?" and then
 *     call createLibrary();
 *   - the remembered folder is missing (an unplugged drive): a clear message, and never a new
 *     empty library.
 * Plus the cross-platform warnings: cloud-synced locations and very long paths.
 */
import { promises as fs } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve, sep } from 'node:path'
import { Store } from './store'
import { EMPTY_LIBRARY, type Profile } from './library'

export type LibraryProbe =
  | { status: 'ok'; warnings: string[] }
  | { status: 'empty'; warnings: string[] }
  | { status: 'missing' }
  | { status: 'not-a-folder' }

export async function probeLibrary(path: string): Promise<LibraryProbe> {
  const st = await fs.stat(path).catch(() => undefined)
  if (!st) return { status: 'missing' }
  if (!st.isDirectory()) return { status: 'not-a-folder' }
  const warnings = pathWarnings(path)
  const lib = await fs.stat(join(path, 'library.json')).catch(() => undefined)
  return lib ? { status: 'ok', warnings } : { status: 'empty', warnings }
}

/** The neutral default profile for a new library: keep_runs 8, wav16, the three saved views with real display rules. */
export function defaultProfile(): Profile {
  return {
    views: {
      note: 'Saved views only change what the dashboard shows. They never affect what is captured.',
      active: '',
      saved: {
        instrumental: {
          label: 'Instrumental / voiceover-safe',
          description: 'Low-vocal tracks, for when a voice has to sit on top.',
          rule: { any: [{ field: 'mood', contains: 'instrumental' }, { field: 'mood', contains: 'ambient' }, { field: 'suits', contains: 'no vocal' }, { field: 'suits', contains: 'instrumental' }] }
        },
        'high-energy': {
          label: 'High energy',
          description: 'Fast, loud, hard transients.',
          rule: { any: [{ field: 'energy', equals: 'high' }] }
        },
        'low-energy': {
          label: 'Low energy',
          description: 'Slower, quieter, more space.',
          rule: { any: [{ field: 'energy', equals: 'low' }] }
        }
      }
    },
    retention: { keep_runs: 8, note: 'Clips kept for pinned tracks, favourites, and the last N runs.' },
    promote: { format: 'wav16', note: 'Format for full tracks pulled when you star something: wav16, wav24 or mp3.' }
  }
}

/** Create the state files for a brand-new library in an existing, empty-of-library folder. */
export async function createLibrary(path: string): Promise<void> {
  const store = new Store(path)
  await fs.mkdir(join(path, 'clips'), { recursive: true })
  await fs.mkdir(join(path, 'full'), { recursive: true })
  await fs.mkdir(join(path, 'pending'), { recursive: true })
  await store.withLock(async () => {
    const existing = await store.read('library.json')
    if (existing.data !== undefined) throw new Error('A library already exists here')
    await store.writeUnlocked('library.json', EMPTY_LIBRARY())
    await store.writeUnlocked('favourites.json', { ids: [] })
    await store.writeUnlocked('profile.json', defaultProfile())
  })
}

/** Warnings about where the folder is. Heuristics; each is one plain sentence for the UI. */
export function pathWarnings(path: string, opts: { home?: string; platform?: NodeJS.Platform } = {}): string[] {
  const home = opts.home ?? homedir()
  const platform = opts.platform ?? process.platform
  const p = resolve(path)
  const lower = p.toLowerCase()
  const under = (base: string) => lower === base.toLowerCase() || lower.startsWith(base.toLowerCase() + sep)
  const warnings: string[] = []

  const synced =
    lower.includes(`${sep}onedrive`) ||
    lower.includes(`${sep}mobile documents${sep}`) ||
    lower.includes(`${sep}icloud drive`) ||
    lower.includes(`${sep}dropbox`) ||
    lower.includes(`${sep}google drive`) ||
    (platform === 'darwin' && (under(join(home, 'Desktop')) || under(join(home, 'Documents'))))
  if (synced) {
    warnings.push(
      platform === 'win32'
        ? 'This folder looks cloud-synced (OneDrive or similar). Synced folders can offload files, and DaVinci Resolve then loses the media mid-edit. The Videos or Music folder is a safer place.'
        : 'This folder may be synced by iCloud (Desktop and Documents often are). Synced folders can offload files, and DaVinci Resolve then loses the media mid-edit. The Movies folder is a safer place.'
    )
  }
  // Windows limits full paths to 260 characters unless long paths are enabled. full/<id>/<id>.source.webm can add ~140.
  if (p.length > 110) {
    warnings.push(`This folder's path is ${p.length} characters long. Files inside it may exceed Windows' 260-character limit; a shorter path is safer.`)
  }
  return warnings
}
