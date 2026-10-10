// Downloads the bundled ffmpeg from a release made by .github/workflows/ffmpeg.yml into
// vendor/ffmpeg/<mac|win>/ and verifies it against the release's SHA256SUMS.
// Usage: node scripts/fetch-ffmpeg.mjs mac|win <release-tag>
// Uses the gh CLI, present on all GitHub runners (GH_TOKEN avoids API rate limits).
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, rmSync, existsSync } from 'node:fs'
import { join } from 'node:path'

const [platform, tag] = process.argv.slice(2)
if (!platform || !tag || !['mac', 'win'].includes(platform)) {
  console.error('usage: fetch-ffmpeg.mjs mac|win <release-tag>')
  process.exit(2)
}
const asset = platform === 'mac' ? 'ffmpeg-mac-universal.zip' : 'ffmpeg-win-x64.zip'
const outDir = join('vendor', 'ffmpeg', platform)
rmSync(outDir, { recursive: true, force: true })
mkdirSync(outDir, { recursive: true })
const tmp = join('vendor', 'ffmpeg', `${platform}-download`)
rmSync(tmp, { recursive: true, force: true })
mkdirSync(tmp, { recursive: true })

execFileSync('gh', ['release', 'download', tag, '--repo', 'jaklusty/soundbites', '--pattern', asset, '--pattern', 'SHA256SUMS', '--dir', tmp], { stdio: 'inherit' })

const sums = readFileSync(join(tmp, 'SHA256SUMS'), 'utf8')
const line = sums.split('\n').find((l) => l.trim().endsWith(` ${asset}`) || l.trim().endsWith(`*${asset}`))
if (!line) throw new Error(`SHA256SUMS has no entry for ${asset}`)
const expected = line.trim().split(/\s+/)[0].toLowerCase()
const actual = createHash('sha256').update(readFileSync(join(tmp, asset))).digest('hex')
if (actual !== expected) throw new Error(`${asset} checksum mismatch: ${actual} != ${expected}`)

if (process.platform === 'win32') {
  execFileSync('tar', ['-xf', join(tmp, asset), '-C', outDir], { stdio: 'inherit' })
} else {
  execFileSync('unzip', ['-o', join(tmp, asset), '-d', outDir], { stdio: 'inherit' })
}
rmSync(tmp, { recursive: true, force: true })
const bin = join(outDir, platform === 'win' ? 'ffmpeg.exe' : 'ffmpeg')
if (!existsSync(bin)) throw new Error(`${bin} missing after extract`)
console.log(`ffmpeg ${tag} verified and placed in ${outDir}`)
