/** "A newer version is available": GitHub Releases of the app's own repository, once a day. */
export const RELEASES_API = 'https://api.github.com/repos/jaklusty/soundbites/releases/latest'
export const RELEASES_PAGE = 'https://github.com/jaklusty/soundbites/releases/latest'

export function compareVersions(a: string, b: string): number {
  const pa = a.replace(/^v/, '').split(/[.-]/).map((x) => (Number.isNaN(Number(x)) ? 0 : Number(x)))
  const pb = b.replace(/^v/, '').split(/[.-]/).map((x) => (Number.isNaN(Number(x)) ? 0 : Number(x)))
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0)
    if (d !== 0) return d
  }
  return 0
}

export async function checkForNewerRelease(currentVersion: string, fetchImpl: typeof fetch = fetch): Promise<{ version: string; url: string } | undefined> {
  try {
    const res = await fetchImpl(RELEASES_API, { headers: { Accept: 'application/vnd.github+json', 'User-Agent': `Soundbites/${currentVersion}` }, signal: AbortSignal.timeout(15_000) })
    if (!res.ok) return undefined
    const data = (await res.json()) as { tag_name?: string; html_url?: string; draft?: boolean; prerelease?: boolean }
    if (!data.tag_name || data.draft || data.prerelease) return undefined
    // Only app releases count; ffmpeg-* releases live in the same repository.
    if (!/^v?\d+\.\d+/.test(data.tag_name)) return undefined
    if (compareVersions(data.tag_name, currentVersion) > 0) return { version: data.tag_name.replace(/^v/, ''), url: data.html_url ?? RELEASES_PAGE }
    return undefined
  } catch {
    return undefined
  }
}
