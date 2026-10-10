import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { slugify, casefold } from '../src/main/engine/ids'

interface Case {
  artist: string
  title: string
  id: string
  expect?: string
}

const cases: Case[] = JSON.parse(readFileSync(join(__dirname, 'fixtures', 'slugify-oracle.json'), 'utf8'))

describe('slugify matches the Python oracle', () => {
  it('reproduces every id in the real library.json (first 87 cases carry the stored id)', () => {
    const real = cases.filter((c) => c.expect !== undefined)
    expect(real.length).toBe(87)
    const wrong = real.filter((c) => slugify(c.artist, c.title) !== c.expect)
    expect(wrong).toEqual([])
  })

  it('matches the Python function on every crafted and random case', () => {
    const wrong = cases
      .map((c) => ({ ...c, got: slugify(c.artist, c.title) }))
      .filter((c) => c.got !== c.id)
    expect(wrong.length, JSON.stringify(wrong.slice(0, 5), null, 1)).toBe(0)
    expect(cases.length).toBeGreaterThan(3000)
  })

  it('is stable for the documented behaviours', () => {
    expect(slugify('Sabrina Carpenter', 'Espresso')).toBe(slugify('sabrina carpenter', 'ESPRESSO'))
    expect(slugify('a-b', 'c')).not.toBe(slugify('a', 'b-c'))
    expect(slugify('', '🎵')).toMatch(/^track-[0-9a-f]{8}$/)
    expect(slugify('', '🎵')).not.toBe(slugify('', '🔥'))
    expect(slugify('宇多田ヒカル', 'First Love')).toMatch(/^first-love-[0-9a-f]{8}$/)
    expect(slugify(null, undefined)).toMatch(/^track-[0-9a-f]{8}$/)
    expect(slugify('A'.repeat(60), 'B'.repeat(60))).toMatch(/^a{50}-[0-9a-f]{8}$/)
  })

  it('casefold follows Python where toLowerCase does not', () => {
    expect(casefold('Straße')).toBe('strasse')
    expect(casefold('ΟΔΥΣΣΕΥΣ')).toBe('οδυσσευσ')
    expect(casefold('İ')).toBe('i̇')
  })
})
