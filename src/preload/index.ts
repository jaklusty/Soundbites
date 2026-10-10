import { contextBridge, ipcRenderer } from 'electron'

// The only surface the sandboxed page can reach. Every entry is a named operation; the page never
// gets raw ipcRenderer, Node or file access. Phase 2 extends this list from a shared contract.
contextBridge.exposeInMainWorld('soundbites', {
  version: (): Promise<string> => ipcRenderer.invoke('app:version')
})
