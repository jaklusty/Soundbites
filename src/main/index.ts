import { app, BrowserWindow, ipcMain, shell } from 'electron'
import { join } from 'node:path'

// Hard requirement 9: one copy of the app per machine. The library-folder lock (for a second
// computer or account) lives in the engine and is added in Phase 2.
if (!app.requestSingleInstanceLock()) {
  app.quit()
}

// Hard requirement 5: no remote content, no navigation, no new windows.
function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1200,
    height: 820,
    minWidth: 800,
    minHeight: 560,
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false
    }
  })

  win.webContents.on('will-navigate', (event) => event.preventDefault())
  win.webContents.setWindowOpenHandler(({ url }) => {
    // Links to YouTube (and only http/https) open in the user's own browser.
    if (/^https?:\/\//i.test(url)) void shell.openExternal(url)
    return { action: 'deny' }
  })
  win.webContents.on('will-attach-webview', (event) => event.preventDefault())

  win.once('ready-to-show', () => win.show())

  // Headless smoke check used by CI: prove the page loaded through the preload bridge, then quit.
  if (process.env['SOUNDBITES_SMOKE']) {
    win.webContents.once('did-finish-load', () => {
      setTimeout(() => {
        void win.webContents
          .executeJavaScript('document.getElementById("app")?.textContent ?? ""')
          .then((text: string) => {
            console.log(`SMOKE ${text}`)
            app.exit(text.startsWith('Soundbites ') ? 0 : 1)
          })
      }, 500)
    })
  }

  if (process.env['ELECTRON_RENDERER_URL']) {
    void win.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    void win.loadFile(join(__dirname, '../renderer/index.html'))
  }
  return win
}

ipcMain.handle('app:version', () => app.getVersion())

app.on('second-instance', () => {
  const [win] = BrowserWindow.getAllWindows()
  if (win) {
    if (win.isMinimized()) win.restore()
    win.focus()
  }
})

app.whenReady().then(() => {
  createWindow()
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
