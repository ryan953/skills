export type BoardAction = { type: string; item: string }

export type BoardTask = {
  id: string
  title: string
  stage: string
  kind: string
  owner: string | null
  url: string | null
  parts: string
  actions: BoardAction[]
}

export type Board = {
  generatedAt: string
  counts: {
    open: number
    needsYou: number
    archive: number
    close: number
    queue: number
    backlog: number
  }
  tasks: BoardTask[]
}

export type SyncState = { isSyncing: boolean; error: string | null; at: number | null }

declare module 'claude-code' {
  interface PluginState {
    taskboard: { board: Shaped<Board | null>; sync: SyncState }
  }
}
