/**
 * The contract between the engine (main process) and the page. The preload exposes exactly these
 * operations as window.soundbites; nothing else crosses the bridge.
 */
import type { Track, Profile } from '../main/engine/library'
import type { HealthRecord } from '../main/engine/health'
import type { AppSettings } from '../main/engine/settings'
import type { LockOwner } from '../main/engine/libraryLock'
import type { IngestResult } from '../main/engine/ingest'

export type LibraryStatus =
  | { status: 'none' }
  | { status: 'open'; path: string; warnings: string[] }
  | { status: 'missing'; path: string }
  | { status: 'empty'; path: string; warnings: string[] }
  | { status: 'held'; path: string; owner: LockOwner }
  | { status: 'stale'; path: string; owner?: LockOwner }
  | { status: 'error'; path: string; message: string }

export interface FeedStatus {
  lastChecked?: string
  lastResult?: string
  runsWaiting: number
  archiveRuns: number
  downloading?: { run: string; done: number; total: number; current?: string; paused: boolean }
  queueLength: number
}

export interface ToolsStatus {
  ytdlp?: string
  deno?: string
  ffmpeg?: string
  message?: string
}

export interface AppState {
  version: string
  platform: NodeJS.Platform
  library: LibraryStatus
  tracks: Track[]
  lastRun?: string
  favourites: string[]
  promoteQueue: string[]
  promoting?: string
  profile: Profile
  activeView: string
  health: {
    issues: HealthRecord[]
    pending: string[]
    lastRun?: IngestResult
    reclaimable: { count: number; bytes: number }
  }
  feed: FeedStatus
  tools: ToolsStatus
  settings: AppSettings
  update?: { version: string; url: string }
}

export interface ViewRule {
  any?: ViewCondition[]
  all?: ViewCondition[]
}
export interface ViewCondition {
  field: 'energy' | 'mood' | 'suits' | 'direction' | 'platform' | 'licence' | 'bpm' | 'notes' | 'title' | 'artist'
  equals?: string
  contains?: string
  min?: number
  max?: number
}

/** Operations the page may invoke. Every one returns the fresh state or a small result. */
export interface SoundbitesApi {
  getState(): Promise<AppState>
  onState(cb: (state: AppState) => void): () => void
  chooseLibraryFolder(): Promise<AppState>
  createLibraryHere(path: string): Promise<AppState>
  reopenLibrary(): Promise<AppState>
  takeOverLock(): Promise<AppState>
  star(id: string, on: boolean): Promise<AppState>
  reclaim(): Promise<{ removed: number; freed: number }>
  setActiveView(key: string): Promise<AppState>
  saveViewRule(key: string, rule: ViewRule): Promise<AppState>
  updateSettings(patch: Partial<AppSettings>): Promise<AppState>
  openExternal(url: string): Promise<void>
  showInFolder(kind: 'clip' | 'full', id: string): Promise<void>
  startDrag(kind: 'clip' | 'full', id: string): void
  retryTrack(id: string): Promise<AppState>
  wrongTrack(id: string, alsoRemoveFull: boolean): Promise<AppState>
  setTrackLink(id: string, url: string): Promise<AppState>
  checkFeedNow(): Promise<AppState>
  pauseDownloads(paused: boolean): Promise<AppState>
  cancelDownloads(): Promise<AppState>
  clearIssue(index: number): Promise<AppState>
}

export const IPC = {
  getState: 'state:get',
  stateChanged: 'state:changed',
  chooseLibraryFolder: 'library:choose',
  createLibraryHere: 'library:create',
  reopenLibrary: 'library:reopen',
  takeOverLock: 'library:takeover',
  star: 'track:star',
  reclaim: 'library:reclaim',
  setActiveView: 'view:set',
  saveViewRule: 'view:rule',
  updateSettings: 'settings:update',
  openExternal: 'shell:open',
  showInFolder: 'shell:show',
  startDrag: 'shell:drag',
  retryTrack: 'track:retry',
  wrongTrack: 'track:wrong',
  setTrackLink: 'track:link',
  checkFeedNow: 'feed:check',
  pauseDownloads: 'feed:pause',
  cancelDownloads: 'feed:cancel',
  clearIssue: 'health:clear'
} as const
