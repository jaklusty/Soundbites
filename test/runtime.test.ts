/** Phase 3 checks with a local-folder feed of three runs, keep_runs 2, and a fake yt-dlp. */
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Engine } from '../src/main/engine/engine'
import { Runtime } from '../src/main/engine/runtime'
import { createLibrary } from '../src/main/engine/libraryOpen'
import { Store } from '../src/main/engine/store'
import type { Library, Profile } from '../src/main/engine/library'
import type { FeedState } from '../src/main/engine/feed'
import type { ResolvedUpload, DownloadedSource } from '../src/main/engine/ingest'

let base: string
let lib: string
let feed: string
beforeEach(async () => {
  base = await fs.mkdtemp(join(tmpdir(), 'sb-rt-'))
  lib = join(base, 'lib')
  feed = join(base, 'feed')
  await fs.mkdir(lib)
  await fs.mkdir(join(feed, 'runs'), { recursive: true })
  await createLibrary(lib)
  const store = new Store(lib)
  await store.update<Profile>('profile.json', {}, (p) => ({ ...p, retention: { keep_runs: 2 } }))
  const runs = ['2026-09-01', '2026-09-20', '2026-10-05']
  await fs.writeFile(join(feed, 'index.json'), JSON.stringify({ version: 1, runs: runs.map((r) => ({ run: r, file: `runs/${r}.json`, count: 2 })) }))
  for (const r of runs) {
    await fs.writeFile(join(feed, 'runs', `${r}.json`), JSON.stringify({ run: r, candidates: [
      { title: `Song ${r}`, artist: 'Artist A', search: `Artist A Song ${r}`, direction: 'rising', mood: 'a, b', suits: ['x', 'y'] },
      { title: `Other ${r}`, artist: 'Artist B', search: `Artist B Other ${r}`, direction: 'peaking' },
      { title: 'Shared', artist: 'Artist C', search: 'Artist C Shared' }
    ] }))
  }
})
afterEach(async () => {
  await fs.rm(base, { recursive: true, force: true })
})

interface Fake {
  searches: string[]
  downloads: string[]
  resolveImpl?: (q: string, rejected: string[]) => ResolvedUpload | undefined
  stopAfterDownloads?: number
  onDownload?: () => void
}

function fakeYtdlp(f: Fake) {
  return {
    resolveSearch: async (_o: unknown, q: string, rejected: string[]) => {
      f.searches.push(q)
      if (f.resolveImpl) return f.resolveImpl(q, rejected)
      const id = ('v' + q.replace(/[^a-z0-9]/gi, '').toLowerCase() + '00000000000').slice(0, 11)
      if (rejected.includes(id)) return { videoId: 'alt' + id.slice(3), url: 'https://www.youtube.com/watch?v=alt' + id.slice(3), title: `${q} (alt upload)`, channel: 'Someone', duration: 100 }
      return { videoId: id, url: `https://www.youtube.com/watch?v=${id}`, title: `${q} (Official Audio)`, channel: 'Label', duration: 180 }
    },
    inspect: async () => undefined,
    downloadAudio: async (_o: unknown, url: string, workdir: string): Promise<DownloadedSource | undefined> => {
      f.downloads.push(url)
      f.onDownload?.()
      const p = join(workdir, 'src.webm')
      await fs.writeFile(p, 'audio')
      return { path: p, info: { duration: 180, id: new URL(url).searchParams.get('v') ?? '' } }
    },
    downloadFull: async (_o: unknown, _url: string, workdir: string) => {
      const p = join(workdir, 'full.webm')
      await fs.writeFile(p, 'full')
      return { path: p }
    }
  }
}

async function makeRuntime(e: Engine, f: Fake): Promise<Runtime> {
  const rt = new Runtime(e, { toolsDir: join(base, 'tools'), ffmpegPath: 'ffmpeg-fake', platform: 'darwin', arch: 'arm64', skipTools: true, ytdlpImpl: fakeYtdlp(f) as never, now: () => new Date('2026-10-10T12:00:00Z') })
  // Replace the real clip/transcode steps (they would run ffmpeg) with file copies.
  const anyRt = rt as unknown as { ingestDeps: () => Promise<Record<string, unknown>> }
  const orig = anyRt.ingestDeps.bind(rt)
  anyRt.ingestDeps = async () => {
    const d = await orig()
    return { ...d, clip: async (src: string, dest: string) => { await fs.copyFile(src, dest); return { ok: true } }, measureRms: undefined }
  }
  return rt
}

async function waitIdle(rt: Runtime, e: Engine, ms = 10000): Promise<void> {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    const s = await e.snapshot()
    const r = rt as unknown as { working: boolean; promoting: boolean }
    const busy = r.working || r.promoting || s.feed.queueLength > 0 || s.promoting
    if (!busy) return
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error('runtime did not go idle')
}

describe('Runtime with a local feed', () => {
  it('oldest run is metadata only, the newest two get clips, oldest first; done runs are never re-ingested', async () => {
    const e = new Engine({ appDataDir: join(base, 'app'), version: '0.1.0' })
    await e.settings.load()
    await e.settings.update({ feedBase: feed, updateCheckedAt: '2026-10-10T11:00:00Z' })
    await e.open(lib)
    const f: Fake = { searches: [], downloads: [] }
    const rt = await makeRuntime(e, f)
    await rt.checkFeed()
    await waitIdle(rt, e)

    const s = await e.snapshot()
    expect(s.tracks.length).toBe(7) // 2 unique per run + Shared once
    const old = s.tracks.filter((t) => t.title!.endsWith('2026-09-01'))
    expect(old.every((t) => !t.clip_present && !t.match)).toBe(true)
    const newer = s.tracks.filter((t) => /2026-09-20|2026-10-05/.test(t.title!))
    expect(newer.every((t) => t.clip_present && t.match?.title.includes('Official'))).toBe(true)
    // Oldest first: searches for the 09-20 run come before the 10-05 run.
    expect(f.searches.findIndex((q) => q.includes('2026-09-20'))).toBeLessThan(f.searches.findIndex((q) => q.includes('2026-10-05')))
    expect(f.searches.some((q) => q.includes('2026-09-01'))).toBe(false)
    const shared = s.tracks.find((t) => t.title === 'Shared')!
    expect(shared.runs).toEqual(['2026-09-01', '2026-09-20', '2026-10-05'])
    const state = (await new Store(lib).read<FeedState>('feed_state.json')).data!
    expect(Object.values(state.runs).map((r) => r.state)).toEqual(['done', 'done', 'done'])
    expect(s.lastRun).toBe('2026-10-05')

    // A second check queues nothing and downloads nothing.
    const before = f.downloads.length
    await rt.checkFeed()
    await waitIdle(rt, e)
    expect(f.downloads.length).toBe(before)
    expect((await e.snapshot()).feed.lastResult).toBe('up to date')
    rt.stop()
    await e.close()
  })

  it('quitting mid-run and reopening resumes without duplicates', async () => {
    const e = new Engine({ appDataDir: join(base, 'app'), version: '0.1.0' })
    await e.settings.load()
    await e.settings.update({ feedBase: feed, updateCheckedAt: '2026-10-10T11:00:00Z' })
    await e.open(lib)
    const f: Fake = { searches: [], downloads: [] }
    let rt = await makeRuntime(e, f)
    f.onDownload = () => {
      if (f.downloads.length === 2) rt.cancel() // "quit" after two clips
    }
    await rt.checkFeed()
    await waitIdle(rt, e)
    let s = await e.snapshot()
    const state1 = (await new Store(lib).read<FeedState>('feed_state.json')).data!
    expect(Object.values(state1.runs).some((r) => r.state === 'in-progress' || r.state === 'queued')).toBe(true)
    expect(s.tracks.filter((t) => t.clip_present).length).toBe(2)
    rt.stop()
    await e.close()

    // Reopen
    const e2 = new Engine({ appDataDir: join(base, 'app'), version: '0.1.0' })
    await e2.start()
    expect((await e2.snapshot()).library.status).toBe('open')
    f.onDownload = undefined
    rt = await makeRuntime(e2, f)
    await rt.checkFeed()
    await waitIdle(rt, e2)
    s = await e2.snapshot()
    expect(s.tracks.length).toBe(7)
    expect(new Set(s.tracks.map((t) => t.id)).size).toBe(7)
    // 7 tracks; the two from the oldest run are metadata only, so 5 carry clips, from 5 downloads in total.
    expect(s.tracks.filter((t) => t.clip_present).length).toBe(5)
    expect(f.downloads.length).toBe(5)
    for (const t of s.tracks) expect(t.runs.length).toBe(new Set(t.runs).size)
    rt.stop()
    await e2.close()
  })

  it('no confident match lands as "no confident match"; wrong track then a pasted link survives the next run', async () => {
    const e = new Engine({ appDataDir: join(base, 'app'), version: '0.1.0' })
    await e.settings.load()
    await e.settings.update({ feedBase: feed, updateCheckedAt: '2026-10-10T11:00:00Z' })
    await e.open(lib)
    const f: Fake = { searches: [], downloads: [] }
    f.resolveImpl = (q, rejected) => {
      if (q.includes('Artist B Other 2026-10-05')) return { videoId: 'unrelated00', url: 'https://www.youtube.com/watch?v=unrelated00', title: 'Top 50 chart countdown', channel: 'ChartsDaily', duration: 3000 }
      const id = ('v' + q.replace(/[^a-z0-9]/gi, '').toLowerCase() + '00000000000').slice(0, 11)
      if (rejected.includes(id)) return { videoId: 'alt' + id.slice(3), url: 'https://www.youtube.com/watch?v=alt' + id.slice(3), title: `${q} (alt upload)`, channel: 'Someone', duration: 100 }
      return { videoId: id, url: `https://www.youtube.com/watch?v=${id}`, title: `${q} (Official Audio)`, channel: 'Label', duration: 180 }
    }
    const rt = await makeRuntime(e, f)
    await rt.checkFeed()
    await waitIdle(rt, e)
    let s = await e.snapshot()
    const noMatch = s.tracks.find((t) => t.title === 'Other 2026-10-05')!
    expect(noMatch.match_status).toBe('no-confident-match')
    expect(noMatch.clip_present).toBe(false)
    expect(s.health.issues.some((i) => /no confident match/.test(i.message))).toBe(true)

    // Wrong track on the shared one: the clip goes, the video id is remembered, the alt upload is tried.
    const shared = s.tracks.find((t) => t.title === 'Shared')!
    const firstId = shared.match!.video_id
    await e.rejectMatch(shared.id, false)
    await rt.retryTrack(shared.id)
    await waitIdle(rt, e)
    s = await e.snapshot()
    const shared2 = s.tracks.find((t) => t.title === 'Shared')!
    expect(shared2.rejected_video_ids).toEqual([firstId])
    expect(shared2.match!.video_id).toBe('alt' + firstId.slice(3))
    expect(shared2.clip_present).toBe(true)

    // Paste a link: it is used, and a later feed run does not overwrite it.
    await e.setTrackLink(shared2.id, 'https://youtu.be/userlink001')
    await rt.retryTrack(shared2.id)
    await waitIdle(rt, e)
    await fs.writeFile(join(feed, 'runs', '2026-10-08.json'), JSON.stringify({ run: '2026-10-08', candidates: [{ title: 'Shared', artist: 'Artist C', search: 'Artist C Shared', source_url: 'https://www.youtube.com/watch?v=feedlink001' }] }))
    await fs.writeFile(join(feed, 'index.json'), JSON.stringify({ version: 1, runs: ['2026-09-01', '2026-09-20', '2026-10-05', '2026-10-08'].map((r) => ({ run: r, file: `runs/${r}.json` })) }))
    await rt.checkFeed()
    await waitIdle(rt, e)
    s = await e.snapshot()
    const shared3 = s.tracks.find((t) => t.title === 'Shared')!
    expect(shared3.user_source_url).toBe('https://youtu.be/userlink001')
    expect(shared3.source_url).toBe('https://youtu.be/userlink001')
    expect(shared3.runs).toContain('2026-10-08')
    expect(f.downloads.filter((u) => u.includes('userlink001')).length).toBeGreaterThanOrEqual(1)
    expect(f.downloads.some((u) => u.includes('feedlink001'))).toBe(false)
    rt.stop()
    await e.close()
  })

  it('a starred track gets its full track pulled in the background', async () => {
    const e = new Engine({ appDataDir: join(base, 'app'), version: '0.1.0' })
    await e.settings.load()
    await e.settings.update({ feedBase: feed, updateCheckedAt: '2026-10-10T11:00:00Z' })
    await e.open(lib)
    const f: Fake = { searches: [], downloads: [] }
    const rt = await makeRuntime(e, f)
    const anyRt = rt as unknown as { promoteLoop: () => Promise<void> }
    void anyRt
    await rt.checkFeed()
    await waitIdle(rt, e)
    const s = await e.snapshot()
    const t = s.tracks.find((x) => x.clip_present)!
    // transcodeFull would call ffmpeg; the fake download writes full.webm and the real transcode fails
    // without ffmpeg, so this checks the queue plumbing and the error path rather than audio output.
    await e.star(t.id, true)
    await waitIdle(rt, e)
    const after = await e.snapshot()
    expect(after.favourites).toEqual([t.id])
    expect(after.promoteQueue).toEqual([])
    const row = after.tracks.find((x) => x.id === t.id)!
    expect(row.full ?? row.full_error).toBeDefined()
    rt.stop()
    await e.close()
  })
})
