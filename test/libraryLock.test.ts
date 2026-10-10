import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { LibraryLock, LOCK_DIR_NAME } from '../src/main/engine/libraryLock'

let root: string
beforeEach(async () => {
  root = await fs.mkdtemp(join(tmpdir(), 'sb-lock-'))
})
afterEach(async () => {
  await fs.rm(root, { recursive: true, force: true })
})

describe('LibraryLock', () => {
  it('acquires, writes an owner record, and releases cleanly', async () => {
    const lock = new LibraryLock(root, { heartbeatMs: 100000 })
    expect(await lock.acquire()).toEqual({ status: 'acquired' })
    const owner = JSON.parse(await fs.readFile(join(root, LOCK_DIR_NAME, 'owner.json'), 'utf8'))
    expect(owner.pid).toBe(process.pid)
    expect(owner.app).toBe('Soundbites')
    await lock.release()
    expect(await fs.readdir(root)).not.toContain(LOCK_DIR_NAME)
  })

  it('a second holder sees "held" with the owner while the heartbeat is fresh', async () => {
    const a = new LibraryLock(root, { heartbeatMs: 100000 })
    await a.acquire()
    const b = new LibraryLock(root, { heartbeatMs: 100000 })
    const r = await b.acquire()
    expect(r.status).toBe('held')
    if (r.status === 'held') expect(r.owner.pid).toBe(process.pid)
    await a.release()
  })

  it('a lock with an old heartbeat is reported stale and can be taken over, never silently removed', async () => {
    let t = Date.parse('2026-10-10T10:00:00Z')
    const clock = () => new Date(t)
    const crashed = new LibraryLock(root, { heartbeatMs: 100000, staleAfterMs: 60000, now: clock })
    await crashed.acquire()
    // simulate the crash: process gone, heartbeat stops; time moves on
    t += 5 * 60 * 1000
    const fresh = new LibraryLock(root, { heartbeatMs: 100000, staleAfterMs: 60000, now: clock })
    const r = await fresh.acquire()
    expect(r.status).toBe('stale')
    if (r.status === 'stale') expect(r.owner?.app).toBe('Soundbites')
    // still there: acquire() must not remove it
    expect(await fs.readdir(root)).toContain(LOCK_DIR_NAME)
    expect(await fresh.takeOver()).toEqual({ status: 'acquired' })
    expect(fresh.isHeld).toBe(true)
    await fresh.release()
  })

  it('a lock directory with no readable owner file counts as stale', async () => {
    await fs.mkdir(join(root, LOCK_DIR_NAME))
    const lock = new LibraryLock(root)
    expect(await lock.acquire()).toEqual({ status: 'stale', owner: undefined })
  })

  it('beat() refreshes the heartbeat and keeps the start time', async () => {
    let t = Date.parse('2026-10-10T10:00:00Z')
    const lock = new LibraryLock(root, { heartbeatMs: 100000, now: () => new Date(t) })
    await lock.acquire()
    t += 30000
    await lock.beat()
    const owner = (await lock.readOwner())!
    expect(owner.started).toBe('2026-10-10T10:00:00.000Z')
    expect(owner.heartbeat).toBe('2026-10-10T10:00:30.000Z')
    await lock.release()
  })
})
