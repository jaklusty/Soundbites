import { app, BrowserWindow, dialog, ipcMain, nativeImage, shell, type WebContents } from 'electron'
import { join } from 'node:path'
import { promises as fs } from 'node:fs'
import { Engine } from './engine/engine'
import { registerScheme, installHandler } from './protocol'
import { IPC, type AppState } from '../shared/ipc'
import { EMPTY_LIBRARY, youtubeUrlOnly, type Library } from './engine/library'

// Unpackaged runs would otherwise use "Electron" as the app-data folder name.
app.setName('Soundbites')

// Hard requirement 9: one copy of the app per machine.
if (!app.requestSingleInstanceLock()) {
  app.quit()
}

registerScheme()

const engine = new Engine({ appDataDir: app.getPath('userData'), version: app.getVersion() })
let mainWindow: BrowserWindow | undefined

function send(state: AppState): void {
  for (const w of BrowserWindow.getAllWindows()) {
    if (!w.isDestroyed()) w.webContents.send(IPC.stateChanged, state)
  }
}
engine.on('state', send)

// Hard requirement 5: no remote content, no navigation, no new windows.
function createWindow(): BrowserWindow {
  const saved = engine.settings.current.window
  const win = new BrowserWindow({
    width: saved?.width ?? 1200,
    height: saved?.height ?? 820,
    x: saved?.x,
    y: saved?.y,
    minWidth: 800,
    minHeight: 560,
    show: false,
    autoHideMenuBar: true,
    title: 'Soundbites',
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false
    }
  })
  if (saved?.maximized) win.maximize()

  win.webContents.on('will-navigate', (event) => event.preventDefault())
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) void shell.openExternal(url)
    return { action: 'deny' }
  })
  win.webContents.on('will-attach-webview', (event) => event.preventDefault())

  const saveBounds = () => {
    if (win.isDestroyed()) return
    const b = win.getNormalBounds()
    void engine.settings.update({ window: { ...b, maximized: win.isMaximized() } })
  }
  win.on('resize', debounce(saveBounds, 500))
  win.on('move', debounce(saveBounds, 500))
  win.on('close', saveBounds)

  win.once('ready-to-show', () => win.show())

  if (process.env['SOUNDBITES_SMOKE']) {
    win.webContents.on('console-message', (_e, level, message, line, source) => console.log(`RENDERER[${level}] ${source}:${line} ${message}`))
    win.webContents.on('render-process-gone', (_e, d) => console.log(`RENDERER GONE ${d.reason}`))
    win.webContents.once('did-finish-load', () => {
      setTimeout(() => {
        void win.webContents
          .executeJavaScript(`(async () => {
            const ready = document.body.dataset.ready || ''
            const tracks = document.querySelectorAll('.track').length
            const first = document.querySelector('.track:not(.gone)')?.dataset.id || ''
            const load = (src) => new Promise((res, rej) => {
              const a = document.createElement('audio'); a.preload = 'metadata'; a.src = src
              a.onloadedmetadata = () => res(a); a.onerror = () => rej(new Error('audio error'))
              setTimeout(() => rej(new Error('timeout')), 15000)
            })
            let duration = 0, seekedTo = -1, escapeBlocked = false
            if (first) {
              const a = await load('soundbites://clip/' + encodeURIComponent(first) + '.mp3')
              duration = a.duration
              a.currentTime = Math.min(20, duration / 2)
              await new Promise((res) => { a.onseeked = res; setTimeout(res, 5000) })
              seekedTo = a.currentTime
              escapeBlocked = await load('soundbites://clip/..%2Flibrary.json').then(() => false, () => true)
            }
            return JSON.stringify({ ready, tracks, first, duration, seekedTo, escapeBlocked, stars: document.querySelectorAll('.star[aria-pressed="true"]').length })
          })()`)
          .then((text: string) => {
            console.log(`SMOKE ${text}`)
            const r = JSON.parse(text) as { ready: string; first: string; duration: number; seekedTo: number; escapeBlocked: boolean }
            // With no library configured (CI) the first-launch screen is the expected outcome.
            const ok = (r.ready === 'yes' || r.ready === 'screen:none') && (!r.first || (r.duration > 1 && r.seekedTo > 1 && r.escapeBlocked))
            void engine.close().then(() => app.exit(ok ? 0 : 1))
          })
      }, 1500)
    })
  }

  if (process.env['ELECTRON_RENDERER_URL']) {
    void win.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    void win.loadFile(join(__dirname, '../renderer/index.html'))
  }
  return win
}

function debounce<T extends (...a: never[]) => void>(fn: T, ms: number): T {
  let t: NodeJS.Timeout | undefined
  return ((...args: never[]) => {
    if (t) clearTimeout(t)
    t = setTimeout(() => fn(...args), ms)
  }) as T
}

// ------------------------------------------------------------------ IPC

const state = () => engine.snapshot()

ipcMain.handle(IPC.getState, () => state())

ipcMain.handle(IPC.chooseLibraryFolder, async (e) => {
  const win = BrowserWindow.fromWebContents(e.sender)
  const r = await dialog.showOpenDialog(win ?? mainWindow!, {
    title: 'Choose the folder where your sound library lives',
    properties: ['openDirectory', 'createDirectory'],
    buttonLabel: 'Use this folder'
  })
  if (!r.canceled && r.filePaths[0]) await engine.open(r.filePaths[0])
  return state()
})

ipcMain.handle(IPC.createLibraryHere, async (_e, path: string) => {
  if (typeof path === 'string' && path === engine.libraryPath) await engine.createHere(path)
  return state()
})

ipcMain.handle(IPC.reopenLibrary, async () => {
  const p = engine.settings.current.libraryPath
  if (p) await engine.open(p)
  return state()
})

ipcMain.handle(IPC.takeOverLock, async () => {
  await engine.takeOver()
  return state()
})

ipcMain.handle(IPC.star, async (_e, id: string, on: boolean) => {
  await engine.star(String(id), Boolean(on))
  return state()
})

ipcMain.handle(IPC.reclaim, async () => engine.reclaim())

ipcMain.handle(IPC.setActiveView, async (_e, key: string) => {
  await engine.setActiveView(String(key ?? ''))
  return state()
})

ipcMain.handle(IPC.saveViewRule, async (_e, key: string, rule: unknown) => {
  await engine.saveViewRule(String(key), rule as never)
  return state()
})

ipcMain.handle(IPC.updateSettings, async (_e, patch: Record<string, unknown>) => {
  const allowed: Record<string, unknown> = {}
  for (const k of ['feedBase', 'concurrency', 'requestPauseMs', 'libraryPath'] as const) if (k in patch) allowed[k] = patch[k]
  await engine.updateSettings(allowed)
  return state()
})

ipcMain.handle(IPC.openExternal, async (_e, url: string) => {
  // Links to YouTube open in the user's own browser, after checking they are http(s).
  if (typeof url === 'string' && /^https?:\/\//i.test(url)) await shell.openExternal(url)
})

async function mediaPathFor(kind: 'clip' | 'full', id: string): Promise<string | undefined> {
  const store = engine.store
  if (!store) return undefined
  const lib = await store.readOr<Library>('library.json', EMPTY_LIBRARY())
  const t = lib.tracks.find((x) => x.id === id)
  if (!t) return undefined
  const rel = kind === 'clip' ? (t.clip_present ? t.clip : null) : (t.full ?? null)
  if (!rel) return undefined
  const p = join(store.root, rel)
  return (await fs.stat(p).catch(() => undefined)) ? p : undefined
}

ipcMain.handle(IPC.showInFolder, async (_e, kind: 'clip' | 'full', id: string) => {
  const p = await mediaPathFor(kind, String(id))
  if (p) shell.showItemInFolder(p)
})

// Drag a clip or full track straight into DaVinci Resolve (or anywhere) with the real file path.
ipcMain.on(IPC.startDrag, (e, kind: 'clip' | 'full', id: string) => {
  void mediaPathFor(kind, String(id)).then((p) => {
    if (!p) return
    const icon = dragIcon()
    ;(e.sender as WebContents).startDrag({ file: p, icon })
  })
})

function dragIcon(): Electron.NativeImage {
  // macOS requires a non-empty image. A 1x1 transparent PNG is enough; the OS adds the file badge.
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64')
  return nativeImage.createFromBuffer(png)
}

// Phase 3 wires these to the download queue; until then they report clearly.
ipcMain.handle(IPC.retryTrack, async (_e, id: string) => {
  await engine.recordIssue('downloads', `Try again for ${String(id)} is not available yet in this build.`)
  return state()
})
ipcMain.handle(IPC.wrongTrack, async (_e, id: string, alsoRemoveFull: boolean) => {
  await engine.rejectMatch(String(id), Boolean(alsoRemoveFull))
  return state()
})
ipcMain.handle(IPC.setTrackLink, async (_e, id: string, url: string) => {
  const safe = youtubeUrlOnly(url)
  if (!safe) throw new Error('That is not a YouTube link.')
  await engine.setTrackLink(String(id), safe)
  return state()
})
ipcMain.handle(IPC.checkFeedNow, async () => state())
ipcMain.handle(IPC.pauseDownloads, async () => state())
ipcMain.handle(IPC.cancelDownloads, async () => state())
ipcMain.handle(IPC.clearIssue, async (_e, index: number) => {
  await engine.clearIssue(Number(index))
  return state()
})

// ------------------------------------------------------------------ app lifecycle

app.on('second-instance', () => {
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore()
    mainWindow.focus()
  }
})

app.whenReady().then(async () => {
  if (process.env['SOUNDBITES_SMOKE']) console.log(`USERDATA ${app.getPath('userData')}`)
  installHandler(() => (engine.isOpen ? engine.libraryPath : undefined))
  await engine.start()
  mainWindow = createWindow()
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) mainWindow = createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('before-quit', () => {
  void engine.close()
})
