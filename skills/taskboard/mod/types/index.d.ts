export type BoardAction = { type: string; item: string; reason: string | null }

export type BoardPr = { key: string; label: string; url: string; detail: string | null; headAt: string | null }

export type Progress = { done: number; total: number }

export type TreeNode = {
  id: string
  title: string
  url: string
  state: string
  prs: string[]
  task: string | null
  canDispatch: boolean
}

export type BoardTree = {
  self: string
  parent: { id: string; title: string | null; url: string | null; progress: Progress | null } | null
  progress: Progress | null
  children: TreeNode[]
  siblings: TreeNode[]
  moreSiblings: number
}

export type BoardTask = {
  id: string
  title: string
  stage: string
  kind: string
  owner: string | null
  url: string | null
  parts: string
  actions: BoardAction[]
  prs: BoardPr[]
  tree: BoardTree | null
}

export type Board = {
  generatedAt: string
  counts: {
    open: number
    needsYou: number
    followUp: number
    check: number
    archive: number
    close: number
    queue: number
    backlog: number
  }
  tasks: BoardTask[]
}

export type Worker = {
  session: string
  title: string | null
  task: string
  stage: string
  isOwner: boolean
  turnStartedAt: string
}

export type SyncState = { isSyncing: boolean; error: string | null; at: number | null }

declare module 'claude-code' {
  interface PluginState {
    taskboard: { board: Shaped<Board | null>; sync: SyncState; workers: Shaped<Worker[]>; expanded: string[] }
  }
}
