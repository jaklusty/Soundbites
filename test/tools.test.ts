import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { promises as fs } from 'node:fs'
import { createHash } from 'node:crypto'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import {
  parseChecksums,
  tagFromDownloadUrl,
  versionedFileName,
  pickInstalled,
  compareTags,
  toolSpec,
  installLatest,
  type FetchLike
} from '../src/main/engine/tools'

const GNU = `1fa6733c37ea6fb51c99ad8fe785e7b7e5f3246c9b980230329d4fb72ed8d4d6  yt-dlp
66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a  yt-dlp.exe
0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202  yt-dlp_macos
`
const PS = `

Algorithm : SHA256
Hash      : A0C3101B4158D1DFB7D6A78A7BF0F3DE80C96BB423C152BEEC8BEB22786F2238
Path      : C:\\a\\deno\\deno\\target\\release\\deno-x86_64-pc-windows-msvc.zip

`
const DENO_MAC = `5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c  deno-aarch64-apple-darwin.zip\n`

describe('checksum parsing', () => {
  it('reads GNU-style sums (yt-dlp SHA2-256SUMS)', () => {
    const m = parseChecksums(GNU)
    expect(m.get('yt-dlp_macos')).toBe('0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202')
    expect(m.get('yt-dlp.exe')).toBe('66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a')
    expect(m.size).toBe(3)
  })
  it('reads PowerShell Get-FileHash layout (Deno on Windows), lower-casing the hash', () => {
    const m = parseChecksums(PS)
    expect(m.get('deno-x86_64-pc-windows-msvc.zip')).toBe('a0c3101b4158d1dfb7d6a78a7bf0f3de80c96bb423c152beec8beb22786f2238')
  })
  it('reads the single-line Deno macOS layout', () => {
    expect(parseChecksums(DENO_MAC).get('deno-aarch64-apple-darwin.zip')).toMatch(/^5cd46d/)
  })
  it('handles CRLF and binary-mode asterisks', () => {
    const m = parseChecksums('ab'.repeat(32) + ' *file.bin\r\n')
    expect(m.get('file.bin')).toBe('ab'.repeat(32))
  })
})

describe('tags and names', () => {
  it('extracts the tag from a resolved download URL', () => {
    expect(tagFromDownloadUrl('https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/SHA2-256SUMS')).toBe('2026.08.19')
    expect(tagFromDownloadUrl('https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-apple-darwin.zip.sha256sum')).toBe('v2.9.7')
    expect(tagFromDownloadUrl('https://github.com/x/y/releases/latest/download/f')).toBeUndefined()
  })
  it('builds versioned names per platform', () => {
    expect(versionedFileName(toolSpec('yt-dlp', 'darwin', 'arm64'), '2026.08.19', 'darwin')).toBe('yt-dlp-2026.08.19')
    expect(versionedFileName(toolSpec('yt-dlp', 'win32', 'x64'), '2026.08.19', 'win32')).toBe('yt-dlp-2026.08.19.exe')
    expect(versionedFileName(toolSpec('deno', 'win32', 'x64'), 'v2.9.7', 'win32')).toBe('deno-v2.9.7.exe')
  })
  it('picks the newest installed build and ignores partial downloads', () => {
    const files = ['yt-dlp-2026.07.01', 'yt-dlp-2026.08.19', 'yt-dlp-2026.09.02.part', 'deno-v2.9.7', 'notes.txt']
    expect(pickInstalled(files, toolSpec('yt-dlp', 'darwin', 'arm64'), 'darwin')).toBe('yt-dlp-2026.08.19')
    expect(pickInstalled(['yt-dlp-2026.08.19.exe', 'yt-dlp-2026.09.02.exe'], toolSpec('yt-dlp', 'win32', 'x64'), 'win32')).toBe('yt-dlp-2026.09.02.exe')
    expect(pickInstalled([], toolSpec('deno', 'darwin', 'arm64'), 'darwin')).toBeUndefined()
  })
  it('compares tags numerically', () => {
    expect(compareTags('2026.08.19', '2026.07.01')).toBeGreaterThan(0)
    expect(compareTags('v2.10.0', 'v2.9.7')).toBeGreaterThan(0)
    expect(compareTags('v2.9.7', 'v2.9.7')).toBe(0)
  })
  it('deno asset names follow the platform', () => {
    expect(toolSpec('deno', 'darwin', 'arm64').asset).toBe('deno-aarch64-apple-darwin.zip')
    expect(toolSpec('deno', 'darwin', 'x64').asset).toBe('deno-x86_64-apple-darwin.zip')
    expect(toolSpec('deno', 'win32', 'x64').asset).toBe('deno-x86_64-pc-windows-msvc.zip')
    expect(toolSpec('deno', 'win32', 'x64').zipEntry).toBe('deno.exe')
  })
})

describe('installLatest', () => {
  let dir: string
  beforeEach(async () => {
    dir = await fs.mkdtemp(join(tmpdir(), 'sb-tools-'))
  })
  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true })
  })

  function fakeFetch(files: Record<string, Uint8Array | string>, tag: string): FetchLike {
    return async (url) => {
      const name = url.split('/').pop()!
      const resolved = url.replace('/releases/latest/download/', `/releases/download/${tag}/`)
      const body = files[name]
      if (body === undefined) {
        return { ok: false, status: 404, url: resolved, headers: { get: () => null }, text: async () => '', body: null }
      }
      const bytes = typeof body === 'string' ? new TextEncoder().encode(body) : body
      return {
        ok: true,
        status: 200,
        url: resolved,
        headers: { get: () => null },
        text: async () => new TextDecoder().decode(bytes),
        body: new ReadableStream({
          start(c) {
            c.enqueue(bytes)
            c.close()
          }
        })
      }
    }
  }

  it('downloads, verifies and installs under a versioned name, then is idempotent', async () => {
    const bin = new TextEncoder().encode('#!/bin/sh\necho yt-dlp\n')
    const hash = createHash('sha256').update(bin).digest('hex')
    const spec = toolSpec('yt-dlp', 'darwin', 'arm64')
    const f = fakeFetch({ 'SHA2-256SUMS': `${hash}  yt-dlp_macos\n`, 'yt-dlp_macos': bin }, '2026.08.19')
    const r = await installLatest(spec, 'darwin', dir, f)
    expect(r.tag).toBe('2026.08.19')
    expect(r.alreadyPresent).toBe(false)
    expect(r.path).toBe(join(dir, 'yt-dlp-2026.08.19'))
    const st = await fs.stat(r.path)
    expect(st.mode & 0o111).toBeTruthy()
    expect((await fs.readdir(dir)).filter((n) => n.endsWith('.part'))).toEqual([])
    const again = await installLatest(spec, 'darwin', dir, f)
    expect(again.alreadyPresent).toBe(true)
  })

  it('discards a download whose checksum does not match and installs nothing', async () => {
    const spec = toolSpec('yt-dlp', 'win32', 'x64')
    const f = fakeFetch({ 'SHA2-256SUMS': `${'0'.repeat(64)}  yt-dlp.exe\n`, 'yt-dlp.exe': 'MZ fake' }, '2026.08.19')
    await expect(installLatest(spec, 'win32', dir, f)).rejects.toMatchObject({ code: 'checksum-mismatch' })
    expect(await fs.readdir(dir)).toEqual([])
  })

  it('fails clearly when the checksum list lacks the asset', async () => {
    const spec = toolSpec('yt-dlp', 'darwin', 'x64')
    const f = fakeFetch({ 'SHA2-256SUMS': `${'0'.repeat(64)}  yt-dlp\n` }, '2026.08.19')
    await expect(installLatest(spec, 'darwin', dir, f)).rejects.toMatchObject({ code: 'checksum-missing' })
  })

  it('unzips the single Deno entry through the injected extractor', async () => {
    const zipBytes = new TextEncoder().encode('PK fake zip')
    const hash = createHash('sha256').update(zipBytes).digest('hex')
    const spec = toolSpec('deno', 'win32', 'x64')
    const f = fakeFetch(
      {
        'deno-x86_64-pc-windows-msvc.zip.sha256sum': `Algorithm : SHA256\nHash      : ${hash.toUpperCase()}\nPath      : C:\\x\\deno-x86_64-pc-windows-msvc.zip\n`,
        'deno-x86_64-pc-windows-msvc.zip': zipBytes
      },
      'v2.9.7'
    )
    const extracted: string[] = []
    const r = await installLatest(spec, 'win32', dir, f, async (_zip, entry, dest) => {
      extracted.push(entry)
      await fs.writeFile(dest, 'deno binary')
    })
    expect(extracted).toEqual(['deno.exe'])
    expect(r.path).toBe(join(dir, 'deno-v2.9.7.exe'))
    expect(await fs.readFile(r.path, 'utf8')).toBe('deno binary')
    expect(await fs.readdir(dir)).toEqual(['deno-v2.9.7.exe'])
  })
})
