import { contextBridge, ipcRenderer } from 'electron'
import { IPC, type SoundbitesApi, type AppState } from '../shared/ipc'

// The only surface the sandboxed page can reach: named operations, no raw ipcRenderer, no Node.
const api: SoundbitesApi = {
  getState: () => ipcRenderer.invoke(IPC.getState),
  onState: (cb) => {
    const listener = (_e: unknown, state: AppState) => cb(state)
    ipcRenderer.on(IPC.stateChanged, listener)
    return () => ipcRenderer.removeListener(IPC.stateChanged, listener)
  },
  chooseLibraryFolder: () => ipcRenderer.invoke(IPC.chooseLibraryFolder),
  createLibraryHere: (path) => ipcRenderer.invoke(IPC.createLibraryHere, path),
  reopenLibrary: () => ipcRenderer.invoke(IPC.reopenLibrary),
  takeOverLock: () => ipcRenderer.invoke(IPC.takeOverLock),
  star: (id, on) => ipcRenderer.invoke(IPC.star, id, on),
  reclaim: () => ipcRenderer.invoke(IPC.reclaim),
  setActiveView: (key) => ipcRenderer.invoke(IPC.setActiveView, key),
  saveViewRule: (key, rule) => ipcRenderer.invoke(IPC.saveViewRule, key, rule),
  updateSettings: (patch) => ipcRenderer.invoke(IPC.updateSettings, patch),
  openExternal: (url) => ipcRenderer.invoke(IPC.openExternal, url),
  showInFolder: (kind, id) => ipcRenderer.invoke(IPC.showInFolder, kind, id),
  startDrag: (kind, id) => ipcRenderer.send(IPC.startDrag, kind, id),
  retryTrack: (id) => ipcRenderer.invoke(IPC.retryTrack, id),
  wrongTrack: (id, alsoRemoveFull) => ipcRenderer.invoke(IPC.wrongTrack, id, alsoRemoveFull),
  setTrackLink: (id, url) => ipcRenderer.invoke(IPC.setTrackLink, id, url),
  checkFeedNow: () => ipcRenderer.invoke(IPC.checkFeedNow),
  pauseDownloads: (paused) => ipcRenderer.invoke(IPC.pauseDownloads, paused),
  cancelDownloads: () => ipcRenderer.invoke(IPC.cancelDownloads),
  clearIssue: (index) => ipcRenderer.invoke(IPC.clearIssue, index)
}

contextBridge.exposeInMainWorld('soundbites', api)
