import { describe, it, expect } from 'vitest'
import { ruleMatches, describeRule, isValidRule } from '../src/shared/views'
import { defaultProfile } from '../src/main/engine/libraryOpen'
import type { Track } from '../src/main/engine/library'

const t = (extra: Partial<Track>): Track => ({ id: 'x', first_seen: '2026-01-01', runs: [], clip: null, clip_present: false, ...extra })

describe('saved view rules', () => {
  const saved = defaultProfile().views!.saved!
  it('high energy = energy is high', () => {
    expect(ruleMatches(t({ energy: 'high' }), saved['high-energy']!.rule)).toBe(true)
    expect(ruleMatches(t({ energy: 'medium' }), saved['high-energy']!.rule)).toBe(false)
    expect(ruleMatches(t({}), saved['high-energy']!.rule)).toBe(false)
  })
  it('instrumental looks at mood and suits', () => {
    expect(ruleMatches(t({ mood: ['hard techno', 'instrumental'] }), saved['instrumental']!.rule)).toBe(true)
    expect(ruleMatches(t({ suits: 'Steady club build, no vocal until late' }), saved['instrumental']!.rule)).toBe(true)
    expect(ruleMatches(t({ mood: ['vocal-led'] }), saved['instrumental']!.rule)).toBe(false)
  })
  it('a missing or bad rule shows everything', () => {
    expect(ruleMatches(t({}), undefined)).toBe(true)
    expect(ruleMatches(t({}), { any: [] })).toBe(true)
    expect(isValidRule({ any: [{ field: 'energy', equals: 'low' }] })).toBe(true)
  })
  it('bpm ranges and descriptions', () => {
    expect(ruleMatches(t({ bpm: 128 }), { all: [{ field: 'bpm', min: 120, max: 140 }] })).toBe(true)
    expect(ruleMatches(t({ bpm: 90 }), { all: [{ field: 'bpm', min: 120 }] })).toBe(false)
    expect(describeRule(saved['high-energy']!.rule)).toBe('energy is "high"')
    expect(describeRule({ all: [{ field: 'bpm', min: 120, max: 140 }, { field: 'mood', contains: 'techno' }] })).toBe('bpm between 120 and 140 and mood contains "techno"')
  })
})
