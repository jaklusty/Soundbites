/**
 * health.json: what has gone wrong lately, in the exact shape the Python wrote (events with
 * at/kind/ok/message/detail, capped at 40). The dashboard's Needs-attention strip reads this.
 * Best-effort: a failure to record never breaks the caller.
 */
import type { Store } from './store'

export const MAX_EVENTS = 40

export interface HealthRecord {
  at: string
  kind: string
  ok: boolean
  message: string
  detail: string
}

export interface HealthFile {
  events: HealthRecord[]
  updated?: string
}

export async function record(store: Store, kind: string, ok: boolean, message: string, detail = ''): Promise<void> {
  try {
    await store.update<HealthFile>('health.json', { events: [] }, (data) => {
      const events = Array.isArray(data.events) ? data.events : []
      const now = new Date().toISOString().replace(/\.\d{3}Z$/, '+00:00')
      events.push({ at: now, kind, ok, message, detail })
      return { ...data, events: events.slice(-MAX_EVENTS), updated: now }
    })
  } catch {
    /* best effort */
  }
}

/** Drop earlier events of one kind; used when that thing next succeeds. */
export async function clearKind(store: Store, kind: string): Promise<void> {
  try {
    await store.update<HealthFile>('health.json', { events: [] }, (data) => {
      const events = Array.isArray(data.events) ? data.events : []
      const kept = events.filter((e) => e.kind !== kind)
      if (kept.length === events.length) return undefined
      return { ...data, events: kept }
    })
  } catch {
    /* best effort */
  }
}
