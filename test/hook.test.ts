import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fromHeatmap, fromEnergy, detect, fmt } from '../src/main/engine/hook'

interface Case {
  name: string
  heatmap: { start_time: number; end_time: number; value: number }[]
  duration: number | null
  result: [number, string] | null
}
const cases: Case[] = JSON.parse(readFileSync(join(__dirname, 'fixtures', 'heatmap-oracle.json'), 'utf8'))

describe('heatmap hook detection matches hook.py', () => {
  it('agrees with the Python on every oracle case', () => {
    const wrong: string[] = []
    for (const c of cases) {
      const got = fromHeatmap(c.heatmap, c.duration ?? undefined)
      const exp = c.result
      if (!exp && !got) continue
      if (!exp || !got || Math.abs(got.at - exp[0]) > 1e-6 || got.detail !== exp[1]) {
        wrong.push(`${c.name}: got ${JSON.stringify(got)} expected ${JSON.stringify(exp)}`)
      }
    }
    expect(wrong, wrong.slice(0, 5).join('\n')).toEqual([])
    expect(cases.filter((c) => c.result).length).toBeGreaterThan(50)
  })

  it('rejects garbage', () => {
    expect(fromHeatmap(null, 100)).toBeUndefined()
    expect(fromHeatmap([{ start_time: 'x', end_time: 1, value: 1 }], 100)).toBeUndefined()
    expect(fromHeatmap('nope', 100)).toBeUndefined()
  })
})

describe('energy and the cascade', () => {
  it('finds the loudest sustained window', () => {
    const hop = 8192 / 22050
    const n = Math.floor(200 / hop)
    const rms = new Float32Array(n)
    for (let i = 0; i < n; i++) {
      const t = i * hop
      rms[i] = t >= 90 && t < 125 ? 0.9 : 0.1
    }
    const r = fromEnergy(rms, hop, 200)!
    expect(r.detail).toBe('loudest sustained window')
    expect(r.at).toBeGreaterThan(85)
    expect(r.at).toBeLessThan(95)
  })
  it('short track → 0', () => {
    expect(fromEnergy(new Float32Array(10), 0.37, 20)).toEqual({ at: 0, detail: 'track shorter than the clip' })
  })
  it('explicit wins, then heatmap, then energy, then 0:20', async () => {
    expect((await detect({ explicit: 42, info: { heatmap: cases.find((c) => c.result)!.heatmap } })).method).toBe('explicit')
    const withMap = cases.find((c) => c.result && c.duration)!
    expect((await detect({ info: { heatmap: withMap.heatmap, duration: withMap.duration! } })).method).toBe('heatmap')
    const hop = 8192 / 22050
    const rms = new Float32Array(400).fill(0.1)
    for (let i = 150; i < 250; i++) rms[i] = 1
    const e = await detect({ info: { heatmap: [] }, measureRms: async () => ({ rms, hop, duration: 400 * hop }) })
    expect(e.method).toBe('energy')
    const d = await detect({ info: {} })
    expect(d).toEqual({ at: 20, method: 'default', detail: 'no signal — used 0:20' })
  })
  it('fmt', () => {
    expect(fmt(0)).toBe('0:00')
    expect(fmt(65.4)).toBe('1:05')
    expect(fmt(273.8)).toBe('4:34')
  })
})
