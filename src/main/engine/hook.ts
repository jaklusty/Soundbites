/**
 * Find the most recognisable 30 seconds of a track. Port of hook.py with the chorus method
 * dropped (never used in the library) and the energy method measured with ffmpeg instead of
 * librosa. Order: explicit hook_start → YouTube most-replayed heatmap → loudest 30 s window
 * (recorded as `energy`) → 0:20.
 */

export const WINDOW = 30.0
export const HEAD_SKIP = 10.0
export const TAIL_SKIP = 5.0
export const FLATNESS_MIN = 1.25
export const EXCESS_MIN = 0.08

export interface HeatmapPoint {
  start_time: number
  end_time: number
  value: number
}

export type HookMethod = 'explicit' | 'heatmap' | 'energy' | 'default'

export interface HookResult {
  at: number
  method: HookMethod
  detail: string
}

function clamp(start: number, duration: number | undefined): number {
  if (!duration || duration <= WINDOW) return 0.0
  return Math.max(0.0, Math.min(start, duration - WINDOW))
}

/** Best 30 s window by detrended replay value. Returns undefined when the heatmap has no opinion. */
export function fromHeatmap(heatmap: unknown, duration: number | undefined): { at: number; detail: string } | undefined {
  if (!Array.isArray(heatmap) || heatmap.length < 8) return undefined
  let pts: [number, number, number][]
  try {
    pts = heatmap.map((h: HeatmapPoint) => {
      const t = [Number(h.start_time), Number(h.end_time), Number(h.value)] as [number, number, number]
      if (t.some((x) => Number.isNaN(x))) throw new Error('bad point')
      return t
    })
  } catch {
    return undefined
  }

  let usable = pts.filter((p) => p[0] >= HEAD_SKIP && (!duration || p[1] <= duration - TAIL_SKIP))
  if (usable.length < 5) usable = pts.slice(1).length ? pts.slice(1) : pts
  if (!usable.length) return undefined

  const values = usable.map((p) => p[2])
  const mean = values.reduce((a, b) => a + b, 0) / values.length
  const peak = Math.max(...values)
  if (mean <= 0 || peak / mean < FLATNESS_MIN) return undefined

  // Detrend: subtract a wide moving baseline and score only the excess.
  const n = usable.length
  const span = Math.max(3, Math.floor(n / 5))
  const excess: [number, number][] = usable.map(([a, , v], i) => {
    const lo = Math.max(0, i - span)
    const hi = Math.min(n, i + span + 1)
    let sum = 0
    for (let k = lo; k < hi; k++) sum += values[k]!
    const baseline = sum / (hi - lo)
    return [a, Math.max(0.0, v - baseline)]
  })

  const peakExcess = Math.max(...excess.map((e) => e[1]))
  if (peakExcess < EXCESS_MIN * mean) return undefined

  // A hook rises into; drop-off never does.
  const lookback = WINDOW * 0.7
  const byTime = new Map<number, number>()
  for (const [a, , v] of usable) byTime.set(a, v)
  const risesInto = (start: number): boolean => {
    const before: number[] = []
    const inside: number[] = []
    for (const [a, v] of byTime) {
      if (start - lookback <= a && a < start) before.push(v)
      if (start <= a && a < start + WINDOW) inside.push(v)
    }
    if (!before.length || !inside.length) return false
    return inside.reduce((x, y) => x + y, 0) / inside.length > before.reduce((x, y) => x + y, 0) / before.length
  }

  let bestStart: number | undefined
  let bestScore = -1.0
  for (const [start] of excess) {
    if (!risesInto(start)) continue
    let score = 0
    for (const [a, e] of excess) if (start <= a && a < start + WINDOW) score += e
    if (score > bestScore) {
      bestScore = score
      bestStart = start
    }
  }
  if (bestStart === undefined || bestScore <= 0) return undefined
  return { at: clamp(bestStart, duration), detail: `replay bump, peak ${(peak / mean).toFixed(1)}x average` }
}

/**
 * Loudest sustained 30 s. `rms` is a series of RMS values at `hop` seconds apart (the caller
 * measures it with ffmpeg). Mirrors from_energy in hook.py: candidate starts every hop from
 * HEAD_SKIP to duration-WINDOW-TAIL_SKIP, score = mean RMS inside the window.
 */
export function fromEnergy(rms: ArrayLike<number>, hop: number, duration: number | undefined): { at: number; detail: string } | undefined {
  if (!rms.length) return undefined
  const times = Array.from({ length: rms.length }, (_, i) => i * hop)
  const dur = duration || times[times.length - 1] || 0
  if (dur <= WINDOW) return { at: 0.0, detail: 'track shorter than the clip' }
  let bestStart: number | undefined
  let bestScore = -1.0
  for (let i = 0; i < times.length; i++) {
    const t = times[i]!
    if (t < HEAD_SKIP || t > dur - WINDOW - TAIL_SKIP) continue
    let j = i
    while (j < times.length && times[j]! < t + WINDOW) j++
    let sum = 0
    for (let k = i; k < j; k++) sum += rms[k]!
    const score = sum / Math.max(1, j - i)
    if (score > bestScore) {
      bestScore = score
      bestStart = t
    }
  }
  if (bestStart === undefined) return undefined
  return { at: clamp(bestStart, dur), detail: 'loudest sustained window' }
}

export interface DetectInput {
  /** yt-dlp info dict (for heatmap and duration), if any. */
  info?: { heatmap?: unknown; duration?: number } | undefined
  duration?: number | undefined
  /** An explicit hook_start in seconds; always wins. */
  explicit?: number | undefined
  /** Lazily measures loudness; only called when the heatmap gives nothing. */
  measureRms?: () => Promise<{ rms: ArrayLike<number>; hop: number; duration: number } | undefined>
}

export async function detect(input: DetectInput): Promise<HookResult> {
  if (input.explicit !== undefined && input.explicit !== null) {
    return { at: Number(input.explicit), method: 'explicit', detail: 'set in the run file' }
  }
  const info = input.info ?? {}
  const duration = input.duration || info.duration

  const hm = fromHeatmap(info.heatmap, duration)
  if (hm) return { at: hm.at, method: 'heatmap', detail: hm.detail }

  if (input.measureRms) {
    try {
      const m = await input.measureRms()
      if (m) {
        const e = fromEnergy(m.rms, m.hop, duration || m.duration)
        if (e) return { at: e.at, method: 'energy', detail: e.detail }
      }
    } catch {
      /* fall through to the default */
    }
  }
  return { at: 20.0, method: 'default', detail: 'no signal — used 0:20' }
}

export function fmt(seconds: number): string {
  const total = Math.round(seconds)
  const m = Math.floor(total / 60)
  const s = total % 60
  return `${m}:${s < 10 ? '0' : ''}${s}`
}
