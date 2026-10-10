/**
 * Everything that runs ffmpeg. Always argument arrays, never shell strings (hard requirement 6).
 * The path to the bundled ffmpeg is injected so tests can use the system one.
 */
import { execFile } from 'node:child_process'
import { promises as fs } from 'node:fs'
import { dirname } from 'node:path'

export const CLIP_SECONDS = 30
export const CLIP_BITRATE = '128k'
export const CLIP_CHANNELS = 1

export interface RunResult {
  code: number
  stdout: string
  stderr: string
  timedOut: boolean
}

/** Run a program with a timeout; a hung process never discards a whole run's work. */
export function runTool(file: string, args: string[], opts: { timeoutMs: number; maxBuffer?: number; cwd?: string }): Promise<RunResult> {
  return new Promise((resolve) => {
    execFile(
      file,
      args,
      { timeout: opts.timeoutMs, maxBuffer: opts.maxBuffer ?? 64 * 1024 * 1024, windowsHide: true, cwd: opts.cwd, encoding: 'utf8' },
      (err, stdout, stderr) => {
        const e = err as (NodeJS.ErrnoException & { killed?: boolean; code?: number | string; signal?: string }) | null
        if (!e) return resolve({ code: 0, stdout: String(stdout), stderr: String(stderr), timedOut: false })
        const timedOut = Boolean(e.killed && e.signal === 'SIGTERM')
        const code = typeof e.code === 'number' ? e.code : e.code === 'ENOENT' ? 127 : 1
        resolve({ code: timedOut ? 124 : code, stdout: String(stdout ?? ''), stderr: String(stderr ?? e.message), timedOut })
      }
    )
  })
}

export function lastLine(text: string, fallback = 'no output'): string {
  const lines = text.trim().split(/\r?\n/).filter(Boolean)
  return (lines[lines.length - 1] ?? fallback).slice(0, 160)
}

/** Cut the 30 s audition clip: mono, 44.1 kHz, 128k MP3, no metadata. Same ffmpeg arguments as ingest.py. */
export async function makeClip(ffmpeg: string, src: string, dest: string, hookStart: number): Promise<{ ok: boolean; error?: string }> {
  await fs.mkdir(dirname(dest), { recursive: true })
  const res = await runTool(
    ffmpeg,
    ['-y', '-loglevel', 'error', '-ss', String(hookStart), '-i', src, '-t', String(CLIP_SECONDS), '-ac', String(CLIP_CHANNELS), '-ar', '44100', '-b:a', CLIP_BITRATE, '-map_metadata', '-1', dest],
    { timeoutMs: 120_000 }
  )
  const size = await fs.stat(dest).then((s) => s.size).catch(() => 0)
  if (res.code !== 0 || size === 0) {
    await fs.rm(dest, { force: true })
    return { ok: false, error: res.stderr.trim().slice(0, 200) || `ffmpeg exit ${res.code}` }
  }
  return { ok: true }
}

export const FULL_FORMATS: Record<string, { args: string[]; ext: string }> = {
  wav24: { args: ['-c:a', 'pcm_s24le', '-ar', '48000', '-ac', '2'], ext: 'wav' },
  wav16: { args: ['-c:a', 'pcm_s16le', '-ar', '48000', '-ac', '2'], ext: 'wav' },
  mp3: { args: ['-c:a', 'libmp3lame', '-b:a', '320k', '-ar', '48000', '-ac', '2'], ext: 'mp3' }
}

/** Transcode a full track for Resolve. Same arguments as promote.py. */
export async function transcodeFull(ffmpeg: string, src: string, dest: string, format: string): Promise<{ ok: boolean; error?: string }> {
  const f = FULL_FORMATS[format] ?? FULL_FORMATS['wav16']!
  await fs.mkdir(dirname(dest), { recursive: true })
  const res = await runTool(ffmpeg, ['-y', '-loglevel', 'error', '-i', src, ...f.args, '-map_metadata', '-1', dest], { timeoutMs: 600_000 })
  const size = await fs.stat(dest).then((s) => s.size).catch(() => 0)
  if (res.code !== 0 || size === 0) {
    await fs.rm(dest, { force: true })
    return { ok: false, error: res.stderr.trim().slice(0, 200) || `ffmpeg exit ${res.code}` }
  }
  return { ok: true }
}

export const ANALYSIS_SR = 22050
export const ANALYSIS_HOP = 8192
const FRAME = 2048

/**
 * Loudness series for the energy hook method: decode to mono 22.05 kHz floats and compute the
 * RMS of a 2048-sample frame centred on every 8192nd sample, the way librosa's rms() did.
 */
export async function measureRms(ffmpeg: string, src: string): Promise<{ rms: Float32Array; hop: number; duration: number } | undefined> {
  const res = await runToolBinary(ffmpeg, ['-loglevel', 'error', '-i', src, '-ac', '1', '-ar', String(ANALYSIS_SR), '-f', 'f32le', '-'], 300_000)
  if (!res) return undefined
  const samples = new Float32Array(res.buffer, res.byteOffset, Math.floor(res.byteLength / 4))
  const n = samples.length
  if (n === 0) return undefined
  const frames = Math.floor(n / ANALYSIS_HOP) + 1
  const rms = new Float32Array(frames)
  const half = FRAME / 2
  for (let i = 0; i < frames; i++) {
    const centre = i * ANALYSIS_HOP
    let sum = 0
    for (let k = centre - half; k < centre + half; k++) {
      const v = k >= 0 && k < n ? samples[k]! : 0
      sum += v * v
    }
    rms[i] = Math.sqrt(sum / FRAME)
  }
  return { rms, hop: ANALYSIS_HOP / ANALYSIS_SR, duration: n / ANALYSIS_SR }
}

function runToolBinary(file: string, args: string[], timeoutMs: number): Promise<Buffer | undefined> {
  return new Promise((resolve) => {
    execFile(file, args, { timeout: timeoutMs, maxBuffer: 512 * 1024 * 1024, windowsHide: true, encoding: 'buffer' }, (err, stdout) => {
      if (err) return resolve(undefined)
      resolve(stdout as Buffer)
    })
  })
}

/** Duration in seconds via ffprobe-less parsing: ask ffmpeg to decode nothing and read "Duration:". */
export async function probeDuration(ffmpeg: string, src: string): Promise<number | undefined> {
  const res = await runTool(ffmpeg, ['-hide_banner', '-i', src, '-f', 'null', '-'], { timeoutMs: 60_000 })
  const m = /Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/.exec(res.stderr)
  if (!m) return undefined
  return Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3])
}
