/**
 * soundbites:// serves clips and full tracks from inside the open library to the sandboxed page,
 * with byte-range support so <audio> can seek. Only clips/<id>.mp3 and full/<id>/<file> resolve.
 */
import { protocol, net } from 'electron'
import { createReadStream, promises as fs } from 'node:fs'
import { Readable } from 'node:stream'
import { parseRange, resolveMediaPath, mimeFor } from './engine/ranges'

export const SCHEME = 'soundbites'

export function registerScheme(): void {
  protocol.registerSchemesAsPrivileged([{ scheme: SCHEME, privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, bypassCSP: false } }])
}

export function installHandler(getLibraryRoot: () => string | undefined): void {
  protocol.handle(SCHEME, async (request) => {
    const root = getLibraryRoot()
    if (!root) return new Response('No library open', { status: 503 })
    const path = resolveMediaPath(root, request.url)
    if (!path) return new Response('Not found', { status: 404 })
    const st = await fs.stat(path).catch(() => undefined)
    if (!st || !st.isFile()) return new Response('Not found', { status: 404 })

    const headers: Record<string, string> = {
      'Content-Type': mimeFor(path),
      'Accept-Ranges': 'bytes',
      'Cache-Control': 'no-store'
    }
    if (request.method === 'HEAD') return new Response(null, { status: 200, headers: { ...headers, 'Content-Length': String(st.size) } })

    const range = parseRange(request.headers.get('range'), st.size)
    if (range === null) return new Response('Range not satisfiable', { status: 416, headers: { 'Content-Range': `bytes */${st.size}` } })
    if (range === undefined) {
      const body = Readable.toWeb(createReadStream(path)) as unknown as ReadableStream
      return new Response(body, { status: 200, headers: { ...headers, 'Content-Length': String(st.size) } })
    }
    const body = Readable.toWeb(createReadStream(path, { start: range.start, end: range.end })) as unknown as ReadableStream
    return new Response(body, {
      status: 206,
      headers: { ...headers, 'Content-Length': String(range.end - range.start + 1), 'Content-Range': `bytes ${range.start}-${range.end}/${st.size}` }
    })
  })
}

// net is imported so the module keeps a reference for future fetch use without a second import site.
void net
