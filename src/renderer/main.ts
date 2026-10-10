/**
 * The dashboard. Adapted from the original index.html: same sections, search, chips, playback,
 * starring and footer. The three old mechanisms (library.js, /api/* calls, 30-second polling)
 * are replaced by the bridge: one state snapshot, pushed again whenever anything changes.
 */
import type { AppState, SoundbitesApi, ViewRule } from '../shared/ipc'
import type { Track } from '../main/engine/library'
import { ruleMatches, describeRule } from '../shared/views'

declare global {
  interface Window {
    soundbites: SoundbitesApi
  }
}
const api = window.soundbites
const root = document.getElementById('root')!

let S: AppState | undefined
let favourites = new Set<string>()
let promoteQueue = new Set<string>()
const ui = { q: '', filter: 'all', settingsOpen: false, aboutOpen: false }
let current: { node: HTMLElement; audio: HTMLAudioElement } | undefined
let resumeAfterRender: { id: string; at: number } | undefined

// ---------------------------------------------------------------- helpers

function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)
}
function safeUrl(u: unknown): string {
  const s = String(u ?? '').trim()
  return /^https?:\/\//i.test(s) ? s : ''
}
function fmtUses(n: number | undefined): string {
  if (n == null) return ''
  if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'm uses'
  if (n >= 1e3) return Math.round(n / 1e3) + 'k uses'
  return n + ' uses'
}
function fmtTime(sec: number): string {
  const m = Math.floor(sec / 60)
  const s = Math.round(sec % 60)
  return m + ':' + (s < 10 ? '0' : '') + s
}
function fmtMb(bytes: number): string {
  const mb = bytes / 1e6
  return mb >= 10 ? mb.toFixed(0) + ' MB' : mb >= 1 ? mb.toFixed(1) + ' MB' : Math.round(bytes / 1e3) + ' KB'
}
function fmtWhen(iso: string | undefined): string {
  if (!iso) return 'never'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  const mins = Math.round((Date.now() - d.getTime()) / 60000)
  if (mins < 1) return 'just now'
  if (mins < 60) return `${mins} min ago`
  if (mins < 60 * 24) return `${Math.round(mins / 60)} h ago`
  return d.toLocaleString()
}
function trend(track: Track): string {
  const h = track.uses_history
  if (!h) return ''
  const keys = Object.keys(h).sort()
  if (keys.length < 2) return ''
  const a = h[keys[keys.length - 2]!]!
  const b = h[keys[keys.length - 1]!]!
  if (!a || !b || b === a) return ''
  const pct = Math.round(((b - a) / a) * 100)
  if (Math.abs(pct) < 3) return ''
  return (pct > 0 ? '▲ ' : '▼ ') + Math.abs(pct) + '% since last run'
}
function clipUrl(track: Track): string {
  return `soundbites://clip/${encodeURIComponent(track.clip!.split('/').pop()!)}`
}
function el(html: string): HTMLElement {
  const t = document.createElement('template')
  t.innerHTML = html.trim()
  return t.content.firstElementChild as HTMLElement
}
function act(p: Promise<AppState>): void {
  p.then(apply).catch((err: Error) => {
    notice(err.message.replace(/^Error invoking remote method '[^']+': Error: /, ''))
  })
}
let noticeTimer: number | undefined
function notice(text: string): void {
  let n = document.getElementById('notice')
  if (!n) {
    n = el('<div id="notice" class="warn"></div>')
    document.getElementById('status')?.before(n)
  }
  n.textContent = text
  clearTimeout(noticeTimer)
  noticeTimer = window.setTimeout(() => n?.remove(), 8000)
}

// ---------------------------------------------------------------- filtering

function activeRule(): unknown {
  const key = S?.activeView ?? ''
  return key ? S?.profile.views?.saved?.[key]?.rule : undefined
}
function matchesView(t: Track): boolean {
  return ruleMatches(t, activeRule())
}
function matchesQuery(t: Track): boolean {
  if (!ui.q) return true
  const hay = [t.title, t.artist, t.suits, t.notes, (t.mood ?? []).join(' '), t.energy, t.platform, t.match?.title, t.match?.channel].join(' ').toLowerCase()
  return ui.q.toLowerCase().split(/\s+/).every((term) => hay.includes(term))
}
function matchesFilter(t: Track): boolean {
  switch (ui.filter) {
    case 'rising': return t.direction === 'rising'
    case 'peaking': return t.direction === 'peaking'
    case 'favourite': return favourites.has(t.id)
    case 'clearable': return t.licence === 'clearable'
    case 'pool': return !!t.pinned
    case 'playable': return !!t.clip_present
    case 'noaudio': return !t.clip_present
    default: return true
  }
}
function visible(): Track[] {
  return (S?.tracks ?? []).filter((t) => matchesView(t) && matchesQuery(t) && matchesFilter(t))
}

// ---------------------------------------------------------------- track card

function hookLabel(method: string | undefined): string {
  return ({ heatmap: 'most replayed', chorus: 'chorus', energy: 'loudest part', explicit: 'set by hand', default: 'not detected' } as Record<string, string>)[method ?? ''] ?? method ?? ''
}

function fullLine(t: Track): string {
  if (t.full) {
    const mb = t.full_bytes ? fmtMb(t.full_bytes) : ''
    return `<div class="full"><span class="fullbadge">full track</span> <span class="drag" draggable="true" data-drag="full" title="Drag into Resolve">${esc(t.full.split('/').pop())}</span>` +
      (mb ? ` <span class="dot">·</span> <span class="uses">${mb}</span>` : '') +
      ` <span class="dot">·</span> <span class="uses">drag it into Resolve, or</span> <button class="small" data-act="show-full">${S?.platform === 'win32' ? 'Show in Explorer' : 'Show in Finder'}</button></div>`
  }
  if (promoteQueue.has(t.id) || S?.promoting === t.id) return '<div class="full pending">Pulling the full track…</div>'
  if (t.full_error) return `<div class="full pending">Full track could not be pulled (${esc(t.full_error)}). The audition clip still works.</div>`
  return ''
}

function matchLine(t: Track): string {
  if (t.match_status === 'user-link') return `<div class="match"><b>Link set by you</b> · ${esc(t.user_source_url ?? '')}</div>`
  if (t.match_status === 'no-confident-match') return '<div class="match"><b>No confident match</b> · the search result did not mention this title or artist, so nothing was downloaded.</div>'
  if (t.match) {
    const d = typeof t.match.duration === 'number' ? ` · ${fmtTime(t.match.duration)}` : ''
    return `<div class="match"><b>Matched</b> "${esc(t.match.title)}" by ${esc(t.match.channel)}${d}</div>`
  }
  if (t.clip_present || t.source_url) return '<div class="match"><b>Match</b> not recorded</div>'
  return ''
}

function trackNode(t: Track): HTMLElement {
  const isFav = favourites.has(t.id)
  const dir = t.direction ?? ''
  const bits: string[] = []
  if (t.bpm) bits.push(t.bpm + ' bpm')
  if (t.energy) bits.push(t.energy + ' energy')
  if (t.mood?.length) bits.push(t.mood.join(', '))
  if (t.platform) bits.push(t.platform === 'both' ? 'TikTok + Reels' : t.platform)
  const mv = trend(t)
  const knownDir = ['rising', 'peaking', 'fading'].includes(dir)
  const hookBits = t.hook_at != null
    ? `<span class="dot">·</span> <span class="hook" title="${esc(t.hook_detail ?? '')}">hook at ${esc(fmtTime(t.hook_at))} <span class="faintish">(${esc(hookLabel(t.hook_method))})</span></span>`
    : ''
  const src = safeUrl(t.user_source_url ?? t.source_url)

  const node = el(`<div class="track${t.clip_present ? '' : ' gone'}" data-id="${esc(t.id)}">
    <button class="play" aria-label="Play"${t.clip_present ? '' : ' disabled'}>▶</button>
    <div class="body">
      <div class="name">${esc(t.title)}${t.artist ? ` <span class="artist">· ${esc(t.artist)}</span>` : ''}</div>
      <div class="meta">
        ${dir && !t.pinned ? `<span class="badge ${knownDir ? esc(dir) : 'fading'}">${esc(dir)}</span>` : ''}
        ${t.licence === 'clearable' ? '<span class="badge clearable">clearable</span>' : ''}
        ${t.pinned ? '<span class="badge pool">extra</span>' : ''}
        ${bits.map((b, i) => (i ? '<span class="dot">·</span>' : '') + `<span>${esc(b)}</span>`).join('')}
        ${hookBits}
        ${src ? ` <span class="dot">·</span> <a href="#" data-act="source">source</a>` : ''}
      </div>
      ${t.suits ? `<div class="suits">${esc(t.suits)}</div>` : ''}
      ${matchLine(t)}
      ${t.clip_present ? '' : `<div class="gonenote">${t.match_status === 'no-confident-match' ? 'No clip for this one yet.' : (t.source_url || t.user_source_url || t.runs?.length) ? 'Clip not on disk. The research is kept.' : 'No source could be found for this one.'}</div>`}
      ${fullLine(t)}
      <div class="actions">
        ${t.clip_present ? `<button class="small drag" draggable="true" data-drag="clip" title="Drag the clip into Resolve">⇅ drag clip</button><button class="small" data-act="show-clip">${S?.platform === 'win32' ? 'Show in Explorer' : 'Show in Finder'}</button>` : ''}
        ${!t.clip_present ? `<button class="small" data-act="retry">${t.match_status === 'no-confident-match' || t.hook_at == null ? 'Try again' : 'Get clip again'}</button>` : ''}
        ${t.clip_present || t.match ? '<button class="small" data-act="wrong">Wrong track</button>' : ''}
        <button class="small" data-act="link">Paste a YouTube link</button>
      </div>
      <div class="linkform" hidden></div>
    </div>
    <div class="side">
      <button class="star" aria-pressed="${isFav}" title="Favourite (keeps the clip and pulls the full track)">${isFav ? '★' : '☆'}</button>
      ${t.uses ? `<span class="uses">${esc(fmtUses(t.uses))}</span>` : ''}
      ${mv ? `<span class="uses">${esc(mv)}</span>` : ''}
    </div>
  </div>`)

  node.querySelector('.play')!.addEventListener('click', () => togglePlay(node, t))
  node.querySelector('.star')!.addEventListener('click', () => toggleStar(node, t))
  node.querySelectorAll<HTMLElement>('[data-drag]').forEach((h) => {
    h.addEventListener('dragstart', (e) => {
      e.preventDefault()
      api.startDrag(h.dataset['drag'] as 'clip' | 'full', t.id)
    })
  })
  node.querySelectorAll<HTMLElement>('[data-act]').forEach((b) => {
    b.addEventListener('click', (e) => {
      e.preventDefault()
      const a = b.dataset['act']
      if (a === 'source' && src) void api.openExternal(src)
      if (a === 'show-clip') void api.showInFolder('clip', t.id)
      if (a === 'show-full') void api.showInFolder('full', t.id)
      if (a === 'retry') { (b as HTMLButtonElement).disabled = true; act(api.retryTrack(t.id)) }
      if (a === 'wrong') wrongTrack(t)
      if (a === 'link') linkForm(node, t)
    })
  })
  return node
}

function wrongTrack(t: Track): void {
  const removeFull = t.full ? confirm(`This track also has a full download (${t.full.split('/').pop()}). Remove that too?`) : false
  if (!confirm(`Mark "${t.title}" as the wrong track? The clip will be removed, this upload will never be matched again, and the next search result will be tried.`)) return
  act(api.wrongTrack(t.id, removeFull))
}

function linkForm(node: HTMLElement, t: Track): void {
  const box = node.querySelector<HTMLElement>('.linkform')!
  if (!box.hidden) { box.hidden = true; box.innerHTML = ''; return }
  box.hidden = false
  box.innerHTML = `<div class="inline-form"><input type="text" placeholder="https://www.youtube.com/watch?v=…" spellcheck="false"><button class="small">Use this link</button></div>
    <div class="rule">The clip will be cut from this upload instead. A link you set is never replaced by a later feed run.</div>`
  const input = box.querySelector('input')!
  box.querySelector('button')!.addEventListener('click', () => {
    const v = input.value.trim()
    if (!v) return
    act(api.setTrackLink(t.id, v))
  })
  input.focus()
}

// ---------------------------------------------------------------- sections

function section(title: string, blurb: string, tracks: Track[]): HTMLElement | null {
  if (!tracks.length) return null
  const s = document.createElement('section')
  s.appendChild(el(`<div class="sechead"><h2>${esc(title)}</h2><span class="count">${tracks.length}</span></div>`))
  if (blurb) s.appendChild(el(`<div class="blurb">${esc(blurb)}</div>`))
  tracks.forEach((t) => s.appendChild(trackNode(t)))
  return s
}

function renderMain(main: HTMLElement): void {
  const resume = current ? { id: current.node.dataset['id']!, at: current.audio.currentTime } : resumeAfterRender
  resumeAfterRender = undefined
  stop()
  const list = visible()
  const lastRun = S?.lastRun ?? null
  const pool = list.filter((t) => t.pinned)
  const rest = list.filter((t) => !t.pinned)
  const thisRun = rest.filter((t) => t.last_seen === lastRun)
  const older = rest.filter((t) => t.last_seen !== lastRun)
  const fresh = thisRun.filter((t) => t.direction === 'rising')
  const working = thisRun.filter((t) => t.direction !== 'rising')
  const favs = older.filter((t) => favourites.has(t.id))
  const archive = older.filter((t) => !favourites.has(t.id))

  main.innerHTML = ''
  const parts = [
    section('Fresh — rising', 'Caught in the acceleration phase. Post within 48–72 hours or the reach advantage is gone.', fresh),
    section('Still working', 'Seen this run, but peaking or already broad. Safe, less upside.', working),
    section('Kept — favourites', 'Starred in earlier runs, so their clips survive the retention sweep.', favs),
    section('Earlier runs', 'Not in the latest run. Metadata kept; clips pruned unless starred.', archive),
    section('Extras — always here', 'Not trend data. A standing set of genre suggestions, kept playable so there is always something to browse beyond this week\'s chart. Ignore freely.', pool)
  ].filter((p): p is HTMLElement => !!p)

  if (!parts.length) {
    main.innerHTML = `<div class="empty">Nothing matches. ${S?.tracks.length ? 'Try clearing the search or filter.' : 'No runs yet. The feed is checked automatically; new sounds appear here as they arrive.'}</div>`
    return
  }
  parts.forEach((p) => main.appendChild(p))

  if (resume) {
    const node = main.querySelector<HTMLElement>(`.track[data-id="${CSS.escape(resume.id)}"]`)
    const track = S?.tracks.find((t) => t.id === resume.id)
    if (node && track?.clip_present) {
      togglePlay(node, track)
      if (current) current.audio.currentTime = resume.at
    }
  }
}

// ---------------------------------------------------------------- audio

function stop(): void {
  if (!current) return
  current.audio.pause()
  current.audio.remove()
  current.node.classList.remove('playing')
  current.node.querySelector('.play')!.textContent = '▶'
  current = undefined
}

function togglePlay(node: HTMLElement, t: Track): void {
  if (current && current.node === node) { stop(); return }
  stop()
  if (!t.clip_present || !t.clip) return
  const audio = document.createElement('audio')
  audio.controls = true
  audio.autoplay = true
  audio.preload = 'metadata'
  audio.src = clipUrl(t)
  audio.addEventListener('ended', stop)
  audio.addEventListener('error', () => {
    node.querySelector('.body')!.insertAdjacentHTML('beforeend', '<div class="gonenote">That clip would not play. The file may have been removed; "Get clip again" fetches it.</div>')
    stop()
  })
  node.querySelector('.body')!.appendChild(audio)
  node.classList.add('playing')
  node.querySelector('.play')!.textContent = '❚❚'
  current = { node, audio }
}

// ---------------------------------------------------------------- actions

function toggleStar(node: HTMLElement, t: Track): void {
  const on = !favourites.has(t.id)
  const btn = node.querySelector<HTMLButtonElement>('.star')!
  btn.disabled = true
  if (current && current.node === node) resumeAfterRender = { id: t.id, at: current.audio.currentTime }
  act(api.star(t.id, on))
}

// ---------------------------------------------------------------- chrome

function renderStatus(box: HTMLElement): void {
  if (!S) return
  const h = S.health
  const bits: string[] = []
  h.issues.forEach((i, idx) => {
    bits.push(`<li><button class="dismiss" title="Dismiss" data-idx="${idx}">×</button><b>${esc(i.message)}</b>${i.detail ? ` <span class="dot">·</span> ${esc(i.detail)}` : ''}</li>`)
  })
  if (h.pending.length) bits.push(`<li><b>${h.pending.length} run file(s) waiting in pending/.</b> They are picked up automatically.</li>`)
  if (S.library.status === 'open' && S.library.warnings.length) S.library.warnings.forEach((w) => bits.push(`<li><b>${esc(w)}</b></li>`))
  if (S.tools.message) bits.push(`<li><b>${esc(S.tools.message)}</b></li>`)

  let html = ''
  if (bits.length) html += `<div class="status bad"><b>Needs attention</b><ul>${bits.join('')}</ul></div>`
  else if (h.lastRun) html += `<div class="status info">Last run <b>${esc(h.lastRun.run)}</b> — ${h.lastRun.added} new, ${h.lastRun.updated} updated${h.lastRun.no_audio ? `, ${h.lastRun.no_audio} without audio` : ''}. Everything is up to date.</div>`

  if (h.reclaimable.count) {
    html += `<div class="status info">${h.reclaimable.count} full track(s) you have unstarred are still using ${fmtMb(h.reclaimable.bytes)}.<br><button class="act" id="reclaim">Free that space</button></div>`
  }
  if (S.update) html += `<div class="status info">A newer version of Soundbites is available (${esc(S.update.version)}). <a href="#" id="updlink">Download it</a>.</div>`
  box.innerHTML = html
  box.querySelectorAll<HTMLButtonElement>('.dismiss').forEach((b) => b.addEventListener('click', () => act(api.clearIssue(Number(b.dataset['idx'])))))
  const btn = box.querySelector<HTMLButtonElement>('#reclaim')
  if (btn) btn.addEventListener('click', () => {
    btn.disabled = true
    btn.textContent = 'Freeing…'
    api.reclaim().then((r) => notice(`Freed ${fmtMb(r.freed)} from ${r.removed} full track(s).`)).catch(() => notice('Could not free that space.'))
  })
  box.querySelector('#updlink')?.addEventListener('click', (e) => { e.preventDefault(); if (S?.update) void api.openExternal(S.update.url) })
}

function feedLine(): string {
  if (!S) return ''
  const f = S.feed
  const parts = [`Feed checked ${fmtWhen(f.lastChecked)}${f.lastResult ? ` (${esc(f.lastResult)})` : ''}`]
  if (f.runsWaiting) parts.push(`${f.runsWaiting} run(s) waiting`)
  if (f.downloading) {
    const d = f.downloading
    parts.push(`<span>Run ${esc(d.run)}: ${d.done} of ${d.total}${d.current ? ` · ${esc(d.current)}` : ''}</span><progress max="${d.total}" value="${d.done}"></progress><button class="small" id="pause">${d.paused ? 'Resume' : 'Pause'}</button><button class="small" id="cancel">Cancel</button>`)
  }
  return parts.join(' <span class="dot">·</span> ')
}

function buildChips(box: HTMLElement): void {
  const defs: [string, string][] = [['all', 'All'], ['rising', 'Rising'], ['peaking', 'Peaking'], ['favourite', '★ Favourites'], ['clearable', 'Clearable'], ['pool', 'Extras'], ['playable', 'Has clip'], ['noaudio', 'No clip']]
  box.innerHTML = ''
  defs.forEach(([key, label]) => {
    const b = el(`<button class="chip" aria-pressed="${ui.filter === key}">${label}</button>`)
    b.addEventListener('click', () => { ui.filter = key; render() })
    box.appendChild(b)
  })
}

function viewsSelect(): string {
  const saved = S?.profile.views?.saved ?? {}
  const keys = Object.keys(saved)
  if (!keys.length) return ''
  return `<select id="view" title="Saved view (changes only what is shown)"><option value="">Everything</option>${keys.map((k) => `<option value="${esc(k)}"${k === S?.activeView ? ' selected' : ''}>${esc(saved[k]!.label ?? k)}</option>`).join('')}</select>`
}

function storageLine(): string {
  if (!S) return ''
  const T = S.tracks
  const clipped = T.filter((t) => t.clip_present)
  const clipB = clipped.reduce((n, t) => n + (t.clip_bytes ?? 480000), 0)
  const fulls = T.filter((t) => t.full)
  const fullB = fulls.reduce((n, t) => n + (t.full_bytes ?? 0), 0)
  return `${T.length} tracked · ${clipped.length} audition clips (${fmtMb(clipB)}) · ${fulls.length} full tracks (${fmtMb(fullB)}) · ${favourites.size} favourites`
}

// ---------------------------------------------------------------- settings panel

function settingsPanel(): HTMLElement {
  const s = S!.settings
  const saved = S!.profile.views?.saved ?? {}
  const p = el(`<div class="panel" id="settings">
    <h3>Settings</h3>
    <label>Library folder</label>
    <div class="row"><span class="path">${esc(S!.library.status === 'none' ? 'none chosen' : (S!.library as { path: string }).path)}</span><button class="small" id="chooseLib">Change…</button></div>
    <label>Feed address (an https address, or a folder on this computer)</label>
    <input type="text" id="feedBase" value="${esc(s.feedBase)}" spellcheck="false">
    <label>Downloads at a time (1 to 3)</label>
    <input type="number" id="conc" min="1" max="3" value="${s.concurrency}">
    <label>Pause between requests to YouTube (seconds)</label>
    <input type="number" id="pause" min="0" max="30" value="${(s.requestPauseMs / 1000).toFixed(0)}">
    <div class="row"><button class="btn" id="saveSettings">Save</button></div>
    <h3 style="margin-top:18px">Saved views</h3>
    <div class="rule">Views only change what is shown. Each rule is a list of conditions; a track shows when any of them match.</div>
    ${Object.keys(saved).map((k) => `<div style="margin-top:8px"><b>${esc(saved[k]!.label ?? k)}</b> <span class="rule">— ${esc(describeRule(saved[k]!.rule))}</span><div class="rule">${esc(saved[k]!.description ?? '')}</div>
      <div class="inline-form"><select data-view="${esc(k)}" class="vf"><option value="energy">energy is</option><option value="mood">mood contains</option><option value="suits">description contains</option><option value="direction">direction is</option><option value="licence">licence is</option><option value="platform">platform is</option></select><input type="text" data-view="${esc(k)}" class="vv" placeholder="value"><button class="small" data-view="${esc(k)}" data-addcond="1">Replace rule with this</button></div></div>`).join('')}
  </div>`)
  p.querySelector('#chooseLib')!.addEventListener('click', () => act(api.chooseLibraryFolder()))
  p.querySelector('#saveSettings')!.addEventListener('click', () => {
    const feedBase = (p.querySelector('#feedBase') as HTMLInputElement).value
    const concurrency = Number((p.querySelector('#conc') as HTMLInputElement).value)
    const requestPauseMs = Number((p.querySelector('#pause') as HTMLInputElement).value) * 1000
    act(api.updateSettings({ feedBase, concurrency, requestPauseMs }))
    notice('Settings saved.')
  })
  p.querySelectorAll<HTMLButtonElement>('[data-addcond]').forEach((b) => {
    b.addEventListener('click', () => {
      const k = b.dataset['view']!
      const field = (p.querySelector(`select.vf[data-view="${CSS.escape(k)}"]`) as HTMLSelectElement).value as ViewRule['any'] extends (infer C)[] | undefined ? C extends { field: infer F } ? F : never : never
      const value = (p.querySelector(`input.vv[data-view="${CSS.escape(k)}"]`) as HTMLInputElement).value.trim()
      if (!value) return
      const rule: ViewRule = field === 'energy' || field === 'direction' || field === 'licence' || field === 'platform' ? { any: [{ field, equals: value }] } : { any: [{ field, contains: value }] }
      act(api.saveViewRule(k, rule))
    })
  })
  return p
}

function aboutPanel(): HTMLElement {
  return el(`<div class="panel" id="about">
    <h3>About Soundbites ${esc(S?.version ?? '')}</h3>
    <div class="rule">Bundled: ffmpeg and ffprobe (LGPL v2.1 or later, built from unmodified FFmpeg source with LAME for MP3). Downloaded on first run and kept up to date: yt-dlp (Unlicense) and Deno (MIT). Licence texts are in the LICENSES folder next to the app, and the ffmpeg source and build recipe are attached to each ffmpeg release at github.com/jaklusty/soundbites.</div>
    <div class="rule" style="margin-top:6px">Tools: yt-dlp ${esc(S?.tools.ytdlp ?? 'not installed yet')} · Deno ${esc(S?.tools.deno ?? 'not installed yet')} · ffmpeg ${esc(S?.tools.ffmpeg ?? 'bundled')}</div>
  </div>`)
}

// ---------------------------------------------------------------- screens

function renderScreen(): boolean {
  if (!S) return false
  const L = S.library
  if (L.status === 'open') return false
  let html = ''
  if (L.status === 'none') {
    html = `<div class="screen"><h1>Soundbites</h1><p>Choose the folder where your sound library lives. If you have one already, pick it; if not, pick an empty folder and Soundbites will start a new library there.</p>
      <p>On a Mac the Movies folder is a good home. On Windows, Videos or Music. Avoid iCloud or OneDrive folders: they can offload files while you are editing.</p>
      <button class="btn" id="choose">Choose folder…</button></div>`
  } else if (L.status === 'missing') {
    html = `<div class="screen"><h1>Library not found</h1><p>The library folder is not where it was last time. If it is on an external drive, plug it in and try again. Nothing has been changed and no new library has been created.</p>
      <div class="path">${esc(L.path)}</div><button class="btn" id="retry">Try again</button><button class="btn secondary" id="choose">Choose a different folder…</button></div>`
  } else if (L.status === 'empty') {
    html = `<div class="screen"><h1>Start a new library here?</h1><p>This folder has no library in it yet.</p><div class="path">${esc(L.path)}</div>
      ${L.warnings.map((w) => `<div class="warn">${esc(w)}</div>`).join('')}
      <button class="btn" id="create">Yes, start a new library here</button><button class="btn secondary" id="choose">Choose a different folder…</button></div>`
  } else if (L.status === 'held') {
    html = `<div class="screen"><h1>Library in use</h1><p>Another copy of Soundbites is using this library: ${esc(L.owner.app)} on <b>${esc(L.owner.host)}</b> (user ${esc(L.owner.user)}), last seen ${fmtWhen(L.owner.heartbeat)}. Only one can write at a time.</p>
      <div class="path">${esc(L.path)}</div><button class="btn" id="retry">Try again</button><button class="btn secondary" id="choose">Choose a different folder…</button></div>`
  } else if (L.status === 'stale') {
    html = `<div class="screen"><h1>A previous session did not close properly</h1><p>${L.owner ? `${esc(L.owner.app)} on <b>${esc(L.owner.host)}</b> left a lock behind on ${esc(fmtWhen(L.owner.heartbeat))} and has not been seen since.` : 'A lock was left behind.'} If no other computer is using this library right now, you can take it over.</p>
      <div class="path">${esc(L.path)}</div><button class="btn" id="takeover">Take over</button><button class="btn secondary" id="choose">Choose a different folder…</button></div>`
  } else if (L.status === 'error') {
    html = `<div class="screen"><h1>This library could not be opened</h1><p>${esc(L.message)}</p><p>Nothing has been changed.</p>
      <div class="path">${esc(L.path)}</div><button class="btn" id="retry">Try again</button><button class="btn secondary" id="choose">Choose a different folder…</button></div>`
  }
  root.innerHTML = html
  document.body.dataset['ready'] = `screen:${L.status}`
  root.querySelector('#choose')?.addEventListener('click', () => act(api.chooseLibraryFolder()))
  root.querySelector('#retry')?.addEventListener('click', () => act(api.reopenLibrary()))
  root.querySelector('#create')?.addEventListener('click', () => act(api.createLibraryHere((L as { path: string }).path)))
  root.querySelector('#takeover')?.addEventListener('click', () => act(api.takeOverLock()))
  return true
}

function render(): void {
  if (!S) return
  if (renderScreen()) return
  const existing = document.getElementById('main')
  if (!existing) {
    root.innerHTML = `<header>
      <div class="titlebar"><h1>Soundbites</h1><span class="runinfo" id="runinfo"></span>
        <div class="toolbar"><button class="icon" id="settingsBtn" title="Settings">⚙ Settings</button><button class="icon" id="aboutBtn" title="About">About</button></div></div>
      <div class="controls"><input type="search" id="q" placeholder="Search title, artist, mood, what it suits…" autocomplete="off"><span id="viewbox"></span></div>
      <div class="chips" id="chips"></div>
      <div class="feedline" id="feedline"></div>
      <div id="panels"></div>
      <div id="status"></div>
    </header>
    <main id="main"></main>
    <footer>
      <div><kbd>/</kbd> search &nbsp; <kbd>space</kbd> play/pause &nbsp; <kbd>esc</kbd> clear</div>
      <div id="storage"></div>
      <div style="margin-top:6px">Trending audio is licensed for use inside Reels and TikTok. Cut to the reference, export muted, add the official audio at upload — or pick a <b>clearable</b> track for anything baked into the export.</div>
    </footer>`
    wireKeys()
    root.querySelector('#settingsBtn')!.addEventListener('click', () => { ui.settingsOpen = !ui.settingsOpen; ui.aboutOpen = false; render() })
    root.querySelector('#aboutBtn')!.addEventListener('click', () => { ui.aboutOpen = !ui.aboutOpen; ui.settingsOpen = false; render() })
  }
  const q = document.getElementById('q') as HTMLInputElement
  if (q.value !== ui.q && document.activeElement !== q) q.value = ui.q

  document.getElementById('runinfo')!.innerHTML = (S.lastRun ? `Last run <b>${esc(S.lastRun)}</b>` : 'No runs yet') + ` · ${S.tracks.length} tracked`
  const vb = document.getElementById('viewbox')!
  vb.innerHTML = viewsSelect()
  vb.querySelector('#view')?.addEventListener('change', (e) => act(api.setActiveView((e.target as HTMLSelectElement).value)))
  buildChips(document.getElementById('chips')!)
  const fl = document.getElementById('feedline')!
  fl.innerHTML = feedLine()
  fl.querySelector('#pause')?.addEventListener('click', () => act(api.pauseDownloads(!S!.feed.downloading?.paused)))
  fl.querySelector('#cancel')?.addEventListener('click', () => { if (confirm('Stop the current run? Clips already saved are kept; the run resumes next time.')) act(api.cancelDownloads()) })
  const panels = document.getElementById('panels')!
  panels.innerHTML = ''
  if (ui.settingsOpen) panels.appendChild(settingsPanel())
  if (ui.aboutOpen) panels.appendChild(aboutPanel())
  renderStatus(document.getElementById('status')!)
  renderMain(document.getElementById('main')!)
  document.getElementById('storage')!.textContent = storageLine()
  document.body.dataset['ready'] = 'yes'
}

function wireKeys(): void {
  const q = document.getElementById('q') as HTMLInputElement
  document.addEventListener('keydown', (e) => {
    if (e.key === '/' && document.activeElement !== q) { e.preventDefault(); q.focus(); q.select() }
    else if (e.key === 'Escape') { q.value = ''; ui.q = ''; q.blur(); render() }
    else if (e.key === ' ' && document.activeElement === document.body) {
      e.preventDefault()
      if (current) { stop(); return }
      const first = document.querySelector<HTMLButtonElement>('.play:not(:disabled)')
      first?.click()
    }
  })
  let timer: number | undefined
  q.addEventListener('input', () => {
    clearTimeout(timer)
    timer = window.setTimeout(() => { ui.q = q.value.trim(); render() }, 120)
  })
}

function apply(state: AppState): void {
  S = state
  favourites = new Set(state.favourites)
  promoteQueue = new Set(state.promoteQueue)
  render()
}

api.onState(apply)
api.getState().then(apply).catch(() => {
  root.innerHTML = '<div class="screen"><h1>Soundbites</h1><p>The engine did not answer. Try quitting and opening the app again.</p></div>'
})
