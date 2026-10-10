import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Engine } from '../src/main/engine/engine'
import { createLibrary } from '../src/main/engine/libraryOpen'
import { Store } from '../src/main/engine/store'
import type { Library } from '../src/main/engine/library'

let base: string
let appData: string
let lib: string
beforeEach(async () => {
  base = await fs.mkdtemp(join(tmpdir(), 'sb-engine-'))
  appData = join(base, 'appdata')
  lib = join(base, 'lib')
  await fs.mkdir(appData)
  await fs.mkdir(lib)
})
afterEach(async () => {
  await fs.rm(base, { recursive: true, force: true })
})

function engine(): Engine {
  return new Engine({ appDataDir: appData, version: '0.0.0-test', platform: 'darwin' })
}

describe('Engine', () => {
  it('first launch has no library; an empty folder is reported, never auto-created', async () => {
    const e = engine()
    await e.start()
    expect((await e.snapshot()).library.status).toBe('none')
    expect((await e.open(lib)).status).toBe('empty')
    expect(await fs.readdir(lib)).toEqual([])
    expect((await e.createHere(lib)).status).toBe('open')
    expect((await fs.readdir(lib)).sort()).toContain('library.json')
    await e.close()
  })

  it('a missing remembered folder is reported and nothing is created', async () => {
    const e = engine()
    await e.settings.load()
    await e.settings.update({ libraryPath: join(base, 'unplugged') })
    await e.start()
    const s = await e.snapshot()
    expect(s.library.status).toBe('missing')
    expect(await fs.stat(join(base, 'unplugged')).catch(() => 'absent')).toBe('absent')
  })

  it('a star survives a restart and queues the full track once', async () => {
    await createLibrary(lib)
    const store = new Store(lib)
    await store.update<Library>('library.json', { version: 1, tracks: [] }, (l) => {
      l.tracks.push({ id: 'abc', first_seen: '2026-10-10', runs: ['2026-10-10'], clip: null, clip_present: false, title: 'A', artist: 'B' })
      return l
    })
    let e = engine()
    await e.start()
    await e.open(lib)
    expect(await e.star('abc', true)).toBe(true)
    expect(await e.star('abc', true)).toBe(false)
    let s = await e.snapshot()
    expect(s.favourites).toEqual(['abc'])
    expect(s.promoteQueue).toEqual(['abc'])
    await e.close()

    e = engine()
    await e.start()
    s = await e.snapshot()
    expect(s.library.status).toBe('open')
    expect(s.favourites).toEqual(['abc'])
    await e.star('abc', false)
    expect((await e.snapshot()).favourites).toEqual([])
    await expect(e.star('nope', true)).rejects.toThrow(/No such track/)
    await e.close()
  })

  it('the library lock blocks a second engine and offers take-over when stale', async () => {
    await createLibrary(lib)
    const a = engine()
    await a.open(lib)
    const b = new Engine({ appDataDir: join(base, 'appdata2'), version: 'x' })
    expect((await b.open(lib)).status).toBe('held')
    await a.close()
    // simulate a crash: write a lock with an old heartbeat
    await fs.mkdir(join(lib, 'soundbites.lock'))
    await fs.writeFile(join(lib, 'soundbites.lock', 'owner.json'), JSON.stringify({ host: 'other', user: 'u', pid: 1, app: 'Soundbites', started: '2026-01-01T00:00:00Z', heartbeat: '2026-01-01T00:00:00Z' }))
    expect((await b.open(lib)).status).toBe('stale')
    expect((await b.takeOver()).status).toBe('open')
    await b.close()
  })

  it('wrong track removes the clip, remembers the video id, and a pasted link sticks', async () => {
    await createLibrary(lib)
    const store = new Store(lib)
    await fs.writeFile(join(lib, 'clips', 'abc.mp3'), 'x')
    await store.update<Library>('library.json', { version: 1, tracks: [] }, (l) => {
      l.tracks.push({ id: 'abc', first_seen: '2026-10-10', runs: ['2026-10-10'], clip: 'clips/abc.mp3', clip_present: true, title: 'A', artist: 'B', source_url: 'https://www.youtube.com/watch?v=u5Ee8QrWyhc', match: { video_id: 'u5Ee8QrWyhc', title: 'x', channel: 'y', duration: 1 } })
      return l
    })
    const e = engine()
    await e.open(lib)
    const t = await e.rejectMatch('abc', false)
    expect(t?.clip_present).toBe(false)
    expect(t?.rejected_video_ids).toEqual(['u5Ee8QrWyhc'])
    expect(t?.source_url).toBeUndefined()
    expect(await fs.readdir(join(lib, 'clips'))).toEqual([])
    await e.setTrackLink('abc', 'https://youtu.be/abcdefghijk')
    const s = await e.snapshot()
    expect(s.tracks[0]).toMatchObject({ user_source_url: 'https://youtu.be/abcdefghijk', source_url: 'https://youtu.be/abcdefghijk', match_status: 'user-link' })
    await e.close()
  })
})
