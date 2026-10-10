/** Extract one named entry from a zip file (Deno ships as a single-file zip). */
import { createWriteStream } from 'node:fs'
import { pipeline } from 'node:stream/promises'
import yauzl from 'yauzl'

export function extractZipEntry(zipPath: string, entryName: string, dest: string): Promise<void> {
  return new Promise((resolve, reject) => {
    yauzl.open(zipPath, { lazyEntries: true }, (err, zip) => {
      if (err || !zip) return reject(err ?? new Error('zip open failed'))
      let found = false
      zip.on('entry', (entry: yauzl.Entry) => {
        if (entry.fileName !== entryName) return zip.readEntry()
        found = true
        zip.openReadStream(entry, (e, stream) => {
          if (e || !stream) return reject(e ?? new Error('zip read failed'))
          pipeline(stream, createWriteStream(dest))
            .then(() => {
              zip.close()
              resolve()
            })
            .catch(reject)
        })
      })
      zip.on('end', () => {
        if (!found) reject(new Error(`${entryName} not found in ${zipPath}`))
      })
      zip.on('error', reject)
      zip.readEntry()
    })
  })
}
