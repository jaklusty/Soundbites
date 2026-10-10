import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Store } from '../src/main/engine/store'
import { dryRun, mergeTrack, prune, runIngest, confidentMatch, type IngestDeps } from '../src/main/engine/ingest'
import { normalizeCandidate, parseTs, validRunStamp, newerStamp, youtubeUrlOnly, youtubeVideoId, EMPTY_LIBRARY, type Library, type Candidate } from '../src/main/engine/library'
import { slugify } from '../src/main/engine/ids'

describe('candidate normalisation', () => {
  it('turns a mood string into a list and a suits list into one string', () => {
    const c = normalizeCandidate({ title: 'T', artist: 'A', mood: 'dark, moody; slow', suits: ['one', 'two'] }, 'feed')
    expect(c).toMatchObject({ mood: ['dark', 'moody', 'slow'], suits: 'one two' })
  })
  it('feed candidates lose local-only fields and non-YouTube links', () => {
    const c = normalizeCandidate({ title: 'T', artist: 'A', local: '/x.mp3', pin: true, profiles: ['moto'], hook_start: '0:30', source_url: 'https://example.com/a' }, 'feed') as Candidate
    expect(c.local).toBeUndefined()
    expect(c.pin).toBeUndefined()
    expect(c.profiles).toBeUndefined()
    expect(c.hook_start).toBeUndefined()
    expect(c.source_url).toBeUndefined()
    const yt = normalizeCandidate({ title: 'T', artist: 'A', source_url: 'https://youtu.be/abcdefghijk' }, 'feed') as Candidate
    expect(yt.source_url).toBe('https://youtu.be/abcdefghijk')
  })
  it('pending (hand-dropped) candidates keep hook_start and local', () => {
    const c = normalizeCandidate({ title: 'T', artist: 'A', local: '/x.mp3', hook_start: '0:30', pin: 1 }, 'pending') as Candidate
    expect(c).toMatchObject({ local: '/x.mp3', hook_start: '0:30', pin: true })
  })
  it('rejects a candidate with no title', () => {
    expect(normalizeCandidate({ artist: 'A' }, 'feed')).toEqual({ rejected: '(candidate with no title)' })
  })
  it('helpers', () => {
    expect(parseTs('0:20')).toBe(20)
    expect(parseTs('1:05.9')).toBe(65)
    expect(parseTs(95.7)).toBe(95)
    expect(parseTs('x')).toBe(20)
    expect(parseTs(null)).toBe(20)
    expect(validRunStamp('2026-02-30')).toBe(false)
    expect(validRunStamp('2026-10-10')).toBe(true)
    expect(newerStamp('2026-08-29', '2026-10-10')).toBe('2026-10-10')
    expect(newerStamp(undefined, '2026-10-10')).toBe('2026-10-10')
    expect(newerStamp('2026-10-10', 'junk')).toBe('2026-10-10')
    expect(youtubeUrlOnly('https://www.youtube.com/watch?v=abc')).toBeDefined()
    expect(youtubeUrlOnly('https://music.youtube.com/watch?v=abc')).toBeDefined()
    expect(youtubeUrlOnly('https://notyoutube.com/watch?v=abc')).toBeUndefined()
    expect(youtubeUrlOnly('-https://youtube.com/x')).toBeUndefined()
    expect(youtubeVideoId('https://youtu.be/u5Ee8QrWyhc?t=1')).toBe('u5Ee8QrWyhc')
    expect(youtubeVideoId('https://www.youtube.com/watch?v=u5Ee8QrWyhc')).toBe('u5Ee8QrWyhc')
    expect(youtubeVideoId('https://www.youtube.com/shorts/u5Ee8QrWyhc')).toBe('u5Ee8QrWyhc')
    expect(youtubeVideoId('https://www.youtube.com/watch?v=short')).toBeUndefined()
  })
})

describe('match transparency', () => {
  it('accepts when the title or artist appears in the upload title or channel', () => {
    expect(confidentMatch({ title: 'Bicep - Glue (Official Video)', channel: 'BicepVEVO' }, { title: 'Glue', artist: 'Bicep' })).toBe(true)
    expect(confidentMatch({ title: 'Some random vlog', channel: 'Echo & The Bunnymen' }, { title: 'The Killing Moon', artist: 'Echo & The Bunnymen' })).toBe(true)
    expect(confidentMatch({ title: 'Top 10 songs of 2026', channel: 'ChartsDaily' }, { title: 'Glue', artist: 'Bicep' })).toBe(false)
  })
})

describe('merge and dry run', () => {
  it('dry run counts new, known and duplicate ids', () => {
    const lib: Library = { version: 1, tracks: [{ id: slugify('Bicep', 'Glue'), first_seen: '2026-09-21', runs: ['2026-09-21'], clip: null, clip_present: false }] }
    const cands: Candidate[] = [
      { title: 'Glue', artist: 'Bicep' },
      { title: 'glue', artist: 'BICEP' },
      { title: 'New', artist: 'Someone' }
    ]
    expect(dryRun(lib, cands, '2026-10-10', 8)).toEqual({ run: '2026-10-10', candidates: 3, new: 1, known: 2, keepRuns: 8, duplicateIds: 1 })
  })
  it('merge files a new row with defaults and never overwrites a user-set link', () => {
    const lib = EMPTY_LIBRARY()
    const rec = mergeTrack(lib, { title: 'Glue', artist: 'Bicep', uses: 10, source_url: 'https://youtu.be/aaaaaaaaaaa' }, 'id1', '2026-10-10', null, 0)
    expect(rec).toMatchObject({ id: 'id1', first_seen: '2026-10-10', runs: ['2026-10-10'], clip: null, clip_present: false, mood: [], profiles: [], licence: 'platform', last_seen: '2026-10-10', uses_history: { '2026-10-10': 10 } })
    rec.user_source_url = 'https://youtu.be/bbbbbbbbbbb'
    mergeTrack(lib, { title: 'Glue', artist: 'Bicep', source_url: 'https://youtu.be/ccccccccccc' }, 'id1', '2026-10-12', 'clips/id1.mp3', 123, { at: 20, method: 'default', detail: 'x' })
    expect(rec.source_url).toBe('https://youtu.be/aaaaaaaaaaa')
    expect(rec.runs).toEqual(['2026-10-10', '2026-10-12'])
    expect(rec.clip_present).toBe(true)
    expect(rec.hook_at).toBe(20)
  })
})

describe('runIngest', () => {
  let root: string
  let store: Store
  beforeEach(async () => {
    root = await fs.mkdtemp(join(tmpdir(), 'sb-ingest-'))
    store = new Store(root)
    await fs.mkdir(join(root, 'clips'))
  })
  afterEach(async () => {
    await fs.rm(root, { recursive: true, force: true })
  })

  function deps(overrides: Partial<IngestDeps> = {}): IngestDeps {
    return {
      resolve: async (search) => ({ videoId: 'vid00000001', url: 'https://www.youtube.com/watch?v=vid00000001', title: `${search} (Official)`, channel: 'Channel', duration: 200 }),
      inspect: async () => undefined,
      download: async (_url, workdir) => {
        const p = join(workdir, 'src.webm')
        await fs.writeFile(p, 'audio')
        return { path: p, info: { duration: 200 } }
      },
      clip: async (_src, dest) => {
        await fs.writeFile(dest, 'clipclipclip')
        return { ok: true }
      },
      ...overrides
    }
  }

  const cands: Candidate[] = [
    { title: 'Glue', artist: 'Bicep', search: 'Bicep Glue', direction: 'rising' },
    { title: 'Muscle Drive', artist: 'Wbsound', search: 'Wbsound Muscle Drive' },
    { title: 'glue', artist: 'bicep' }
  ]

  it('files rows first, fills clips, prunes once, writes last_run.json and no health error', async () => {
    const seenPhases: string[] = []
    const r = await runIngest(store, '2026-10-10', cands, deps({ onProgress: (p) => seenPhases.push(p.phase) }))
    expect(r).toMatchObject({ run: '2026-10-10', ok: true, added: 2, updated: 0, no_audio: 0, rejected: 1, clips_kept: 2, tracked: 2 })
    const lib = (await store.read<Library>('library.json')).data!
    expect(lib.last_run).toBe('2026-10-10')
    const glue = lib.tracks.find((t) => t.title === 'Glue')!
    expect(glue.clip_present).toBe(true)
    expect(glue.match).toMatchObject({ video_id: 'vid00000001', title: 'Bicep Glue (Official)', channel: 'Channel', duration: 200 })
    expect(glue.match_status).toBe('matched')
    expect(glue.source_url).toBe('https://www.youtube.com/watch?v=vid00000001')
    expect(seenPhases[0]).toBe('filing')
    expect(seenPhases.at(-1)).toBe('done')
    const last = (await store.read<{ run: string }>('last_run.json')).data!
    expect(last.run).toBe('2026-10-10')
    expect((await store.read<{ events: unknown[] }>('health.json')).data?.events ?? []).toEqual([])
  })

  it('no confident match → row without audio, status recorded, one health line per run', async () => {
    const r = await runIngest(
      store,
      '2026-10-10',
      cands.slice(0, 2),
      deps({ resolve: async () => ({ videoId: 'vid00000002', url: 'https://www.youtube.com/watch?v=vid00000002', title: 'Top 10 songs', channel: 'ChartsDaily', duration: 500 }) })
    )
    expect(r.no_audio).toBe(2)
    expect(r.no_match).toBe(2)
    const lib = (await store.read<Library>('library.json')).data!
    expect(lib.tracks.every((t) => t.match_status === 'no-confident-match' && !t.clip_present)).toBe(true)
    const health = (await store.read<{ events: { message: string }[] }>('health.json')).data!
    expect(health.events).toHaveLength(1)
    expect(health.events[0]!.message).toMatch(/^Run 2026-10-10 downloaded nothing: 2 tracks had no audio/)
  })

  it('a stopped run stays unpruned and resumes without duplicates', async () => {
    let calls = 0
    const first = await runIngest(store, '2026-10-10', cands.slice(0, 2), deps({ shouldStop: () => calls++ >= 1 }))
    expect(first.stopped).toBe(true)
    let lib = (await store.read<Library>('library.json')).data!
    expect(lib.tracks).toHaveLength(2)
    expect(lib.tracks.filter((t) => t.clip_present)).toHaveLength(1)
    let downloads = 0
    const second = await runIngest(store, '2026-10-10', cands.slice(0, 2), deps({ download: async (_u, w) => { downloads++; const p = join(w, 'src.webm'); await fs.writeFile(p, 'a'); return { path: p } } }))
    expect(second.stopped).toBeUndefined()
    expect(downloads).toBe(1)
    lib = (await store.read<Library>('library.json')).data!
    expect(lib.tracks).toHaveLength(2)
    expect(lib.tracks.filter((t) => t.clip_present)).toHaveLength(2)
    expect(lib.tracks[0]!.runs).toEqual(['2026-10-10'])
  })

  it('metadata-only runs file rows and download nothing', async () => {
    let downloads = 0
    const r = await runIngest(store, '2026-09-01', cands.slice(0, 2), deps({ downloadAudio: false, download: async () => { downloads++; return undefined } }))
    expect(downloads).toBe(0)
    expect(r.no_audio).toBe(0)
    const lib = (await store.read<Library>('library.json')).data!
    expect(lib.tracks).toHaveLength(2)
    expect(lib.tracks.every((t) => !t.clip_present)).toBe(true)
  })

  it('prune keeps favourites, pinned and recent runs and sweeps only known ids', async () => {
    const lib: Library = {
      version: 1,
      tracks: [
        { id: 'old', first_seen: '2026-01-01', runs: ['2026-01-01'], clip: 'clips/old.mp3', clip_present: true, clip_bytes: 3 },
        { id: 'fav', first_seen: '2026-01-01', runs: ['2026-01-01'], clip: 'clips/fav.mp3', clip_present: true, clip_bytes: 3 },
        { id: 'pin', first_seen: '2026-01-01', runs: ['2026-01-01'], clip: 'clips/pin.mp3', clip_present: true, pinned: true },
        { id: 'new', first_seen: '2026-10-10', runs: ['2026-10-10'], clip: 'clips/new.mp3', clip_present: true }
      ]
    }
    for (const n of ['old', 'fav', 'pin', 'new', 'stranger']) await fs.writeFile(join(root, 'clips', `${n}.mp3`), 'xxx')
    const r = await prune(lib, root, new Set(['fav']), 1, '2026-10-10')
    expect(r).toEqual({ kept: 3, freed: 3 })
    expect((await fs.readdir(join(root, 'clips'))).sort()).toEqual(['fav.mp3', 'new.mp3', 'pin.mp3', 'stranger.mp3'])
    expect(lib.tracks[0]).toMatchObject({ clip_present: false })
    expect(lib.tracks[0]!.clip_bytes).toBeUndefined()
  })
})
