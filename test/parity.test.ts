/**
 * Phase 1 checks (b) and (c): the TypeScript ingest against the original Python on two copies of
 * the real library. Needs python3 and ffmpeg on PATH and the copies prepared by
 * scripts/prepare-parity.sh. Skipped unless SOUNDBITES_PARITY points at the folder holding
 * py/ and ts/ copies and audio/ test files.
 */
import { describe, it, expect } from 'vitest'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { Store } from '../src/main/engine/store'
import { dryRun, runIngest } from '../src/main/engine/ingest'
import { normalizeCandidate, type Candidate, type Library, type RawCandidate } from '../src/main/engine/library'
import { makeClip } from '../src/main/engine/media'

const run = promisify(execFile)
const base = process.env['SOUNDBITES_PARITY']
const d = base ? describe : describe.skip

d('parity with the Python ingest', () => {
  const py = join(base ?? '', 'py')
  const ts = join(base ?? '', 'ts')
  const audio = join(base ?? '', 'audio')
  const ffmpeg = process.env['FFMPEG'] ?? 'ffmpeg'
  const RUN = '2026-10-10'

  const raw: RawCandidate[] = [
    { title: 'Local One', artist: 'Test Artist', local: join(audio, 'local1.mp3'), hook_start: '0:30', direction: 'rising', uses: 1000, bpm: 120, energy: 'high', mood: ['driving'], suits: 'a test', licence: 'platform', notes: 'parity' },
    { title: 'Déjà Vu (Live)', artist: 'Beyoncé', local: join(audio, 'local2.mp3'), hook_start: 45, direction: 'peaking', mood: ['pop'] },
    { title: 'Time', artist: 'Hans Zimmer', local: join(audio, 'local3.mp3'), hook_start: '0:10', direction: 'peaking', uses: 5 },
    { title: 'Missing Audio', artist: 'Nobody', local: join(audio, 'does-not-exist.mp3'), direction: 'fading' },
    { title: 'local one', artist: 'TEST ARTIST', local: join(audio, 'local1.mp3') }
  ]

  async function writeCandidates(dir: string): Promise<string> {
    const p = join(dir, 'pending', `${RUN}.json`)
    await fs.mkdir(join(dir, 'pending'), { recursive: true })
    await fs.writeFile(p, JSON.stringify({ run: RUN, candidates: raw }, null, 2))
    return p
  }

  it('(b) dry run prints the same counts as ingest.py --dry-run', async () => {
    const file = await writeCandidates(py)
    const res = await run('python3', [join(py, 'ingest.py'), file, '--root', py, '--dry-run'])
    const line = res.stderr.trim().split('\n').pop() ?? ''
    const m = /dry run \((\S+)\): (\d+) candidates, (\d+) new, (\d+) already known, keep-runs (\d+)(?:, (\d+) DUPLICATE ids)?/.exec(line)
    expect(m, line).not.toBeNull()
    const library = JSON.parse(await fs.readFile(join(ts, 'library.json'), 'utf8')) as Library
    const cands = raw.map((r) => normalizeCandidate(r, 'pending')).filter((c): c is Candidate => !('rejected' in c))
    const mine = dryRun(library, cands, RUN, 8)
    expect([mine.run, mine.candidates, mine.new, mine.known, mine.keepRuns, mine.duplicateIds]).toEqual([m![1], +m![2]!, +m![3]!, +m![4]!, +m![5]!, +(m![6] ?? 0)])
  })

  it('(c) a real local-audio ingest leaves the same library.json and clips/', async () => {
    const file = await writeCandidates(py)
    await run('python3', [join(py, 'ingest.py'), file, '--root', py, '--keep-runs', '1'], { maxBuffer: 16e6 }).catch((e: { code?: number; stderr?: string }) => {
      if (e.code !== 2) throw e
    })

    const store = new Store(ts)
    const cands = raw.map((r) => normalizeCandidate(r, 'pending')).filter((c): c is Candidate => !('rejected' in c))
    const result = await runIngest(
      store,
      RUN,
      cands,
      {
        resolve: async () => undefined,
        inspect: async () => undefined,
        download: async () => undefined,
        clip: (src, dest, at) => makeClip(ffmpeg, src, dest, at)
      },
      { keepRuns: 1 }
    )

    const pyLib = JSON.parse(await fs.readFile(join(py, 'library.json'), 'utf8')) as Library
    const tsLib = JSON.parse(await fs.readFile(join(ts, 'library.json'), 'utf8')) as Library
    const norm = (lib: Library) => {
      const copy = JSON.parse(JSON.stringify(lib)) as Library
      delete copy.updated
      for (const t of copy.tracks) if (t.hook_detail === 'set in candidates.json' || t.hook_detail === 'set in the run file') t.hook_detail = 'explicit'
      return copy
    }
    expect(norm(tsLib)).toEqual(norm(pyLib))

    const listing = async (dir: string) => {
      const names = (await fs.readdir(join(dir, 'clips'))).sort()
      const out: Record<string, number> = {}
      for (const n of names) out[n] = (await fs.stat(join(dir, 'clips', n))).size
      return out
    }
    expect(await listing(ts)).toEqual(await listing(py))

    const pyLast = JSON.parse(await fs.readFile(join(py, 'last_run.json'), 'utf8')) as Record<string, unknown>
    const tsLast = JSON.parse(await fs.readFile(join(ts, 'last_run.json'), 'utf8')) as Record<string, unknown>
    delete pyLast['finished']
    delete tsLast['finished']
    expect(tsLast).toEqual(pyLast)
    expect(result.no_audio).toBe(1)

    const pyHealth = JSON.parse(await fs.readFile(join(py, 'health.json'), 'utf8')) as { events: { kind: string; ok: boolean }[] }
    const tsHealth = JSON.parse(await fs.readFile(join(ts, 'health.json'), 'utf8')) as { events: { kind: string; ok: boolean }[] }
    expect(tsHealth.events.map((e) => [e.kind, e.ok])).toEqual(pyHealth.events.map((e) => [e.kind, e.ok]))
  })
})
