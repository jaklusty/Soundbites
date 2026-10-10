import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { probeLibrary, createLibrary, pathWarnings, defaultProfile } from '../src/main/engine/libraryOpen'
import { Settings, normaliseFeedBase, sanitize, DEFAULT_FEED_BASE } from '../src/main/engine/settings'
import { parseRange, resolveMediaPath, mediaUrlForClip, mediaUrlForFull } from '../src/main/engine/ranges'

let root: string
beforeEach(async () => {
  root = await fs.mkdtemp(join(tmpdir(), 'sb-open-'))
})
afterEach(async () => {
  await fs.rm(root, { recursive: true, force: true })
})

describe('opening a library', () => {
  it('missing folder → missing, never creates anything', async () => {
    expect(await probeLibrary(join(root, 'gone'))).toEqual({ status: 'missing' })
    expect(await fs.readdir(root)).toEqual([])
  })
  it('empty folder → empty; createLibrary writes the three files and a neutral profile', async () => {
    const p = join(root, 'lib')
    await fs.mkdir(p)
    expect((await probeLibrary(p)).status).toBe('empty')
    await createLibrary(p)
    expect((await probeLibrary(p)).status).toBe('ok')
    expect(JSON.parse(await fs.readFile(join(p, 'library.json'), 'utf8'))).toEqual({ version: 1, tracks: [] })
    expect(JSON.parse(await fs.readFile(join(p, 'favourites.json'), 'utf8'))).toEqual({ ids: [] })
    const profile = JSON.parse(await fs.readFile(join(p, 'profile.json'), 'utf8'))
    expect(profile.retention.keep_runs).toBe(8)
    expect(profile.promote.format).toBe('wav16')
    expect(Object.keys(profile.views.saved)).toEqual(['instrumental', 'high-energy', 'low-energy'])
    expect(JSON.stringify(profile)).not.toMatch(/jak/i)
    await expect(createLibrary(p)).rejects.toThrow(/already exists/)
  })
  it('a file is not a folder', async () => {
    await fs.writeFile(join(root, 'f'), 'x')
    expect(await probeLibrary(join(root, 'f'))).toEqual({ status: 'not-a-folder' })
  })
  it('warns about synced and long paths', () => {
    const home = '/Users/someone'
    expect(pathWarnings('/Users/someone/Movies/Soundbites', { home, platform: 'darwin' })).toEqual([])
    expect(pathWarnings('/Users/someone/Documents/Soundbites', { home, platform: 'darwin' })[0]).toMatch(/iCloud/)
    expect(pathWarnings('/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/x', { home, platform: 'darwin' })[0]).toMatch(/iCloud/)
    expect(pathWarnings('/Users/someone/OneDrive/x', { home, platform: 'darwin' })).toHaveLength(1)
    expect(pathWarnings('/Users/someone/Desktop/' + 'a'.repeat(120), { home, platform: 'darwin' })).toHaveLength(2)
    expect(defaultProfile().views?.saved?.['high-energy']?.rule).toBeDefined()
  })
})

describe('settings', () => {
  it('defaults, persists and sanitises', async () => {
    const s = new Settings(root)
    const first = await s.load()
    expect(first.feedBase).toBe(DEFAULT_FEED_BASE)
    expect(first.concurrency).toBe(1)
    await s.update({ concurrency: 9, feedBase: 'https://example.com/feed', libraryPath: '/x' })
    const again = await new Settings(root).load()
    expect(again.concurrency).toBe(3)
    expect(again.feedBase).toBe('https://example.com/feed/')
    expect(again.libraryPath).toBe('/x')
  })
  it('feed base normalisation', () => {
    expect(normaliseFeedBase('')).toBe(DEFAULT_FEED_BASE)
    expect(normaliseFeedBase('/tmp/feed')).toBe('/tmp/feed')
    expect(sanitize({ feedBase: 'x', concurrency: 0, requestPauseMs: -5 }).concurrency).toBe(1)
  })
})

describe('audio protocol ranges and paths', () => {
  it('parses ranges', () => {
    expect(parseRange(undefined, 100)).toBeUndefined()
    expect(parseRange('bytes=0-', 100)).toEqual({ start: 0, end: 99 })
    expect(parseRange('bytes=10-20', 100)).toEqual({ start: 10, end: 20 })
    expect(parseRange('bytes=90-500', 100)).toEqual({ start: 90, end: 99 })
    expect(parseRange('bytes=-10', 100)).toEqual({ start: 90, end: 99 })
    expect(parseRange('bytes=100-', 100)).toBeNull()
    expect(parseRange('bytes=5-2', 100)).toBeNull()
    expect(parseRange('items=1-2', 100)).toBeUndefined()
  })
  it('maps only clips and full files inside the library', () => {
    const lib = '/lib/root'
    expect(resolveMediaPath(lib, 'soundbites://clip/abc-123.mp3')).toBe(join(lib, 'clips', 'abc-123.mp3'))
    expect(resolveMediaPath(lib, 'soundbites://full/abc-123/abc-123.wav')).toBe(join(lib, 'full', 'abc-123', 'abc-123.wav'))
    expect(resolveMediaPath(lib, 'soundbites://clip/..%2Flibrary.json')).toBeUndefined()
    expect(resolveMediaPath(lib, 'soundbites://clip/../library.json')).toBeUndefined()
    expect(resolveMediaPath(lib, 'soundbites://full/abc/../../x.wav')).toBeUndefined()
    expect(resolveMediaPath(lib, 'soundbites://other/abc.mp3')).toBeUndefined()
    expect(resolveMediaPath(lib, 'soundbites://clip/abc.json')).toBeUndefined()
    expect(resolveMediaPath(lib, 'file:///etc/passwd')).toBeUndefined()
    expect(resolveMediaPath(lib, 'soundbites://clip/.hidden.mp3')).toBeUndefined()
  })
  it('builds URLs from the stored relative paths', () => {
    expect(mediaUrlForClip('clips/abc-123.mp3')).toBe('soundbites://clip/abc-123.mp3')
    expect(mediaUrlForFull('full/abc-123/abc-123.wav')).toBe('soundbites://full/abc-123/abc-123.wav')
  })
})
