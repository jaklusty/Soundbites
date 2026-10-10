/**
 * Saved views: display rules over track fields. Views only change what is shown, never what is
 * captured. A view with no usable rule shows everything, so a bad rule can never hide the library.
 */
import type { Track } from '../main/engine/library'
import type { ViewRule, ViewCondition } from './ipc'

function fieldText(track: Track, field: ViewCondition['field']): string {
  const v = (track as Record<string, unknown>)[field]
  if (Array.isArray(v)) return v.map(String).join(' ').toLowerCase()
  if (v === null || v === undefined) return ''
  return String(v).toLowerCase()
}

export function conditionMatches(track: Track, c: ViewCondition): boolean {
  if (c.field === 'bpm') {
    const n = typeof track.bpm === 'number' ? track.bpm : NaN
    if (Number.isNaN(n)) return false
    if (c.min !== undefined && n < c.min) return false
    if (c.max !== undefined && n > c.max) return false
    if (c.equals !== undefined && n !== Number(c.equals)) return false
    return true
  }
  const text = fieldText(track, c.field)
  if (c.equals !== undefined) return text === String(c.equals).toLowerCase()
  if (c.contains !== undefined) return text.includes(String(c.contains).toLowerCase())
  return false
}

export function isValidRule(rule: unknown): rule is ViewRule {
  if (!rule || typeof rule !== 'object') return false
  const r = rule as ViewRule
  const conds = [...(r.any ?? []), ...(r.all ?? [])]
  if (!conds.length) return false
  return conds.every((c) => c && typeof c === 'object' && typeof c.field === 'string')
}

export function ruleMatches(track: Track, rule: unknown): boolean {
  if (!isValidRule(rule)) return true
  const anyOk = !rule.any || rule.any.length === 0 || rule.any.some((c) => conditionMatches(track, c))
  const allOk = !rule.all || rule.all.every((c) => conditionMatches(track, c))
  return anyOk && allOk
}

/** One-line plain-English description of a rule for the Settings panel. */
export function describeRule(rule: unknown): string {
  if (!isValidRule(rule)) return 'shows everything'
  const part = (c: ViewCondition) => {
    if (c.field === 'bpm') {
      if (c.min !== undefined && c.max !== undefined) return `bpm between ${c.min} and ${c.max}`
      if (c.min !== undefined) return `bpm at least ${c.min}`
      if (c.max !== undefined) return `bpm at most ${c.max}`
      return `bpm is ${c.equals}`
    }
    return c.equals !== undefined ? `${c.field} is "${c.equals}"` : `${c.field} contains "${c.contains}"`
  }
  const bits: string[] = []
  if (rule.any?.length) bits.push(rule.any.map(part).join(' or '))
  if (rule.all?.length) bits.push(rule.all.map(part).join(' and '))
  return bits.join(', and ')
}
