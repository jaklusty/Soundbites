import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Store, StoreError, type HealthEvent } from '../src/main/engine/store'

let root: string
let events: HealthEvent[]
let store: Store

beforeEach(async () => {
  root = await fs.mkdtemp(join(tmpdir(), 'sb-store-'))
  events = []
  store = new Store(root, { onHealth: (e) => events.push(e), now: () => new Date('2026-10-10T17:05:33.000Z') })
})
afterEach(async () => {
  await fs.rm(root, { recursive: true, force: true })
})

describe('Store', () => {
  it('returns undefined for a missing file', async () => {
    const r = await store.read('library.json')
    expect(r.data).toBeUndefined()
    expect(r.recovered).toBe(false)
  })

  it('writes atomically with a trailing newline and 2-space indent, no temp files left', async () => {
    await store.write('library.json', { version: 1, tracks: [] })
    const text = await fs.readFile(join(root, 'library.json'), 'utf8')
    expect(text).toBe('{\n  "version": 1,\n  "tracks": []\n}\n')
    const files = await fs.readdir(root)
    expect(files.filter((f) => f.includes('.tmp-'))).toEqual([])
  })

  it('keeps non-ASCII characters as written', async () => {
    await store.write('t.json', { title: 'Café — 東京 🎵' })
    expect(await fs.readFile(join(root, 't.json'), 'utf8')).toContain('Café — 東京 🎵')
  })

  it('keeps a .bak of the previous good copy on every write', async () => {
    await store.write('library.json', { v: 1 })
    expect(await fs.readdir(root)).not.toContain('library.json.bak')
    await store.write('library.json', { v: 2 })
    expect(JSON.parse(await fs.readFile(join(root, 'library.json.bak'), 'utf8'))).toEqual({ v: 1 })
    await store.write('library.json', { v: 3 })
    expect(JSON.parse(await fs.readFile(join(root, 'library.json.bak'), 'utf8'))).toEqual({ v: 2 })
  })

  it('restores a corrupt file from .bak, keeps a .corrupt copy, and reports a warning', async () => {
    await store.write('favourites.json', { ids: ['a'] })
    await store.write('favourites.json', { ids: ['a', 'b'] })
    await fs.writeFile(join(root, 'favourites.json'), '{"ids": ["a", "b"')
    const r = await store.read<{ ids: string[] }>('favourites.json')
    expect(r.recovered).toBe(true)
    expect(r.data).toEqual({ ids: ['a'] })
    const files = await fs.readdir(root)
    expect(files).toContain('favourites.json.corrupt-2026-10-10T17-05-33')
    expect(await fs.readFile(join(root, 'favourites.json.corrupt-2026-10-10T17-05-33'), 'utf8')).toBe('{"ids": ["a", "b"')
    expect(JSON.parse(await fs.readFile(join(root, 'favourites.json'), 'utf8'))).toEqual({ ids: ['a'] })
    expect(events).toHaveLength(1)
    expect(events[0]!.level).toBe('warning')
    expect(events[0]!.message).toMatch(/restored from its backup/)
    expect(events[0]!.message).not.toMatch(/python|server|claude/i)
  })

  it('with no usable backup: copies aside, changes nothing, throws corrupt-no-backup', async () => {
    await fs.writeFile(join(root, 'library.json'), 'not json')
    await expect(store.read('library.json')).rejects.toMatchObject({ code: 'corrupt-no-backup' } satisfies Partial<StoreError>)
    expect(await fs.readFile(join(root, 'library.json'), 'utf8')).toBe('not json')
    expect(await fs.readdir(root)).toContain('library.json.corrupt-2026-10-10T17-05-33')
    expect(events[0]!.level).toBe('error')
  })

  it('a corrupt .bak is not usable either', async () => {
    await fs.writeFile(join(root, 'library.json'), '{')
    await fs.writeFile(join(root, 'library.json.bak'), '[')
    await expect(store.read('library.json')).rejects.toMatchObject({ code: 'corrupt-no-backup' })
    expect(await fs.readFile(join(root, 'library.json.bak'), 'utf8')).toBe('[')
  })

  it('never overwrites a good .bak with a corrupt current file', async () => {
    await store.write('p.json', { good: true })
    await store.write('p.json', { good: 2 })
    await fs.writeFile(join(root, 'p.json'), 'garbage')
    // A write while the current file is corrupt must not promote the garbage to .bak
    await store.write('p.json', { good: 3 })
    expect(JSON.parse(await fs.readFile(join(root, 'p.json.bak'), 'utf8'))).toEqual({ good: true })
  })

  it('update() does read-modify-write under one lock and can leave the file untouched', async () => {
    await store.write('c.json', { n: 1 })
    const r = await store.update<{ n: number }>('c.json', { n: 0 }, (cur) => ({ n: cur.n + 1 }))
    expect(r).toEqual({ n: 2 })
    const r2 = await store.update<{ n: number }>('c.json', { n: 0 }, () => undefined)
    expect(r2).toEqual({ n: 2 })
  })

  it('serialises concurrent writers; last write wins and no file is ever half-written', async () => {
    await Promise.all(Array.from({ length: 12 }, (_, i) => store.update<{ n: number }>('c.json', { n: 0 }, (c) => ({ n: c.n + 1 + 0 * i }))))
    expect(JSON.parse(await fs.readFile(join(root, 'c.json'), 'utf8'))).toEqual({ n: 12 })
  })

  it('rejects names that are not plain file names', () => {
    expect(() => store.path('../x.json')).toThrow(StoreError)
    expect(() => store.path('sub/x.json')).toThrow(StoreError)
  })

  it('reports a locked library instead of waiting forever', async () => {
    const slow = new Store(root, { lock: { retries: 1, staleMs: 60000 } })
    let releaseHold!: () => void
    const holding = slow.withLock(() => new Promise<void>((res) => (releaseHold = res)))
    await new Promise((r) => setTimeout(r, 50))
    await expect(slow.write('x.json', {})).rejects.toMatchObject({ code: 'locked' })
    releaseHold()
    await holding
  })
})
