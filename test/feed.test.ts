import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { parseIndex, parseRunFile, planRuns, pendingRunFiles, archivePendingFile, ingestedRuns, folderReader, FeedError, ageDays } from '../src/main/engine/feed'
import { Store } from '../src/main/engine/store'
import { parsePrintLines, baseArgs, cleanQuery, EXTRACTOR_FAILURE } from '../src/main/engine/ytdlp'
import { compareVersions, checkForNewerRelease } from '../src/main/engine/updateCheck'
import { candidateFromTrack } from '../src/main/engine/runtime'

let root: string
beforeEach(async () => {
  root = await fs.mkdtemp(join(tmpdir(), 'sb-feed-'))
})
afterEach(async () => {
  await fs.rm(root, { recursive: true, force: true })
})

describe('feed index and run files', () => {
  it('parses, sorts by date, and refuses a newer feed version', () => {
    const idx = parseIndex(JSON.stringify({ version: 1, runs: [{ run: '2026-10-08', file: 'runs/2026-10-08.json', count: 15 }, { run: '2026-09-21', file: 'runs/2026-09-21.json' }, { run: 'junk', file: 'x' }] }))
    expect(idx.runs.map((r) => r.run)).toEqual(['2026-09-21', '2026-10-08'])
    expect(() => parseIndex(JSON.stringify({ version: 2, runs: [] }))).toThrow(/newer version of the app/)
    expect(() => parseIndex('nope')).toThrow(FeedError)
    expect(() => parseIndex('{}')).toThrow(/no runs/)
  })
  it('parses the real feed files from Audio-Trends', async () => {
    const reader = folderReader('/home/user/Audio-Trends')
    const idx = parseIndex(await reader.text('index.json'))
    expect(idx.runs.length).toBeGreaterThanOrEqual(6)
    const run = parseRunFile(await reader.text(idx.runs[0]!.file), idx.runs[0]!.run)
    expect(run.run).toBe('2026-09-21')
    expect(run.candidates.length).toBe(14)
    expect(run.candidates[0]).toMatchObject({ title: 'Glue', artist: 'Bicep', search: 'Bicep Glue' })
    expect(Array.isArray(run.candidates[0]!.mood)).toBe(true)
    expect(typeof run.candidates[0]!.suits).toBe('string')
  })
  it('plans oldest first, audio only for the newest keep_runs, skipping done runs', () => {
    const idx = parseIndex(JSON.stringify({ version: 1, runs: ['2026-09-01', '2026-09-10', '2026-09-20', '2026-10-05'].map((r) => ({ run: r, file: `runs/${r}.json` })) }))
    const planned = planRuns(idx, new Set(['2026-09-10']), 2, new Date('2026-10-10T00:00:00Z'))
    expect(planned.map((p) => [p.run, p.audio, p.archive])).toEqual([
      ['2026-09-01', false, true],
      ['2026-09-20', true, false],
      ['2026-10-05', true, false]
    ])
    expect(ageDays('2026-09-19', new Date('2026-10-10T12:00:00Z'))).toBe(21)
  })
  it('done runs come from feed_state.json and from track runs', async () => {
    const store = new Store(root)
    await store.write('feed_state.json', { version: 1, runs: { '2026-09-01': { state: 'done' }, '2026-09-05': { state: 'failed' } } })
    await store.write('library.json', { version: 1, tracks: [{ id: 'a', runs: ['2026-09-10', 'junk'] }] })
    expect([...(await ingestedRuns(store))].sort()).toEqual(['2026-09-01', '2026-09-10'])
  })
  it('pending files are ordered by their run field and bad ones are left alone', async () => {
    await fs.mkdir(join(root, 'pending'))
    await fs.writeFile(join(root, 'pending', 'a-later.json'), JSON.stringify({ run: '2026-10-05', candidates: [] }))
    await fs.writeFile(join(root, 'pending', 'b-earlier.json'), JSON.stringify({ run: '2026-09-01', candidates: [] }))
    await fs.writeFile(join(root, 'pending', 'broken.json'), '{')
    await fs.writeFile(join(root, 'pending', 'nodate.json'), JSON.stringify({ candidates: [] }))
    const r = await pendingRunFiles(root)
    expect(r.ok.map((f) => f.run)).toEqual(['2026-09-01', '2026-10-05'])
    expect(r.bad.map((b) => b.path.split('/').pop())).toEqual(['broken.json', 'nodate.json'])
    await archivePendingFile(r.ok[0]!.path)
    await fs.writeFile(join(root, 'pending', 'b-earlier.json'), '{"run":"2026-09-01","candidates":[]}')
    await archivePendingFile(join(root, 'pending', 'b-earlier.json'))
    const archived = await fs.readdir(join(root, 'pending', 'ingested'))
    expect(archived.length).toBe(2)
    expect(await fs.readdir(join(root, 'pending'))).toEqual(expect.arrayContaining(['broken.json', 'nodate.json', 'a-later.json']))
  })
})

describe('yt-dlp wrapper', () => {
  it('builds safe arguments', () => {
    const args = baseArgs({ paths: { ytdlp: 'y', deno: '/d/deno', ffmpeg: '/f/ffmpeg' }, sleepRequests: 2 })
    expect(args).toContain('--no-remote-components')
    expect(args.join(' ')).toContain('--js-runtimes deno:/d/deno')
    expect(args.join(' ')).toContain('--ffmpeg-location /f/ffmpeg')
    expect(args.join(' ')).toContain('--sleep-requests 2')
    expect(args).not.toContain('--cookies-from-browser')
    expect(cleanQuery('a\x00b\x1fc  ')).toBe('a b c')
  })
  it('parses print lines and ignores junk', () => {
    const r = parsePrintLines('u5Ee8QrWyhc\tBicep - Glue\tBicep\t237\nnotanid\tx\ty\tz\nabcdefghijk\tT\tNA\tNA\n')
    expect(r).toEqual([
      { videoId: 'u5Ee8QrWyhc', url: 'https://www.youtube.com/watch?v=u5Ee8QrWyhc', title: 'Bicep - Glue', channel: 'Bicep', duration: 237 },
      { videoId: 'abcdefghijk', url: 'https://www.youtube.com/watch?v=abcdefghijk', title: 'T', channel: '', duration: null }
    ])
    expect(EXTRACTOR_FAILURE.test('ERROR: [youtube] abc: Unable to extract player version')).toBe(true)
    expect(EXTRACTOR_FAILURE.test('ERROR: Video unavailable')).toBe(false)
  })
})

describe('release check and retry candidates', () => {
  it('compares versions and reads the latest release', async () => {
    expect(compareVersions('1.2.0', '1.10.0')).toBeLessThan(0)
    expect(compareVersions('v0.2.0', '0.1.9')).toBeGreaterThan(0)
    const fake = (async () => ({ ok: true, json: async () => ({ tag_name: 'v0.2.0', html_url: 'https://x/r' }) })) as unknown as typeof fetch
    expect(await checkForNewerRelease('0.1.0', fake)).toEqual({ version: '0.2.0', url: 'https://x/r' })
    expect(await checkForNewerRelease('0.2.0', fake)).toBeUndefined()
    const ff = (async () => ({ ok: true, json: async () => ({ tag_name: 'ffmpeg-n8.1.3-3', html_url: 'x' }) })) as unknown as typeof fetch
    expect(await checkForNewerRelease('0.1.0', ff)).toBeUndefined()
  })
  it('rebuilds a candidate from a track record', () => {
    expect(candidateFromTrack({ id: 'x', first_seen: '', runs: [], clip: null, clip_present: false, title: 'Glue', artist: 'Bicep', mood: ['a'] })).toEqual({ title: 'Glue', artist: 'Bicep', search: 'Bicep Glue', mood: ['a'] })
    expect(candidateFromTrack({ id: 'x', first_seen: '', runs: [], clip: null, clip_present: false, title: 'Glue', artist: 'Bicep', source_url: 'https://a', user_source_url: 'https://b' }).source_url).toBe('https://b')
  })
})
