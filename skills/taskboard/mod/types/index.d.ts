export type BoardAction = { type: string; item: string; reason: string | null }

export type BoardPr = { key: string; label: string; title: string; url: string; detail: string | null; headAt: string | null }

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

// One heading in the board's tree. `tasks` are ids in Board.tasks; `prs` are lone PRs that are not tasks.
// `folded` is the default; the pane keeps the keys the user flipped.
export type BoardNode = {
  key: string
  title: string
  url: string | null
  folded: boolean
  count: number
  needsYou: number
  children: BoardNode[]
  tasks: string[]
  prs: BoardPr[]
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
  sections: BoardNode[]
}

export type Worker = {
  session: string
  title: string | null
  task: string
  stage: string
  isOwner: boolean
  turnStartedAt: string
}

export type OverviewNode = TreeNode & { isDone: boolean }

export type Overview = {
  id: string
  title: string
  stage: string
  kind: string
  owner: string | null
  ticket: {
    id: string
    title: string
    url: string
    status: string
    priority: string | null
    assignee: string | null
    labels: string[]
    project: string | null
    cycle: string | null
    team: string | null
    branch: string | null
    description: string
  } | null
  comments: { author: string; at: string; body: string }[]
  moreComments: number
  tree: {
    self: string
    parent: { id: string; title: string; url: string; progress: Progress } | null
    progress: Progress | null
    children: OverviewNode[]
    siblings: OverviewNode[]
  } | null
  items: { key: string; type: string; label: string; title: string; url: string | null; detail: string | null }[]
  actions: BoardAction[]
}

export type OverviewState = { id: string | null; isLoading: boolean; error: string | null }

export type SyncState = { isSyncing: boolean; error: string | null; at: number | null }

// The last Clean up press: where the request went, or why it went nowhere.
export type CleanupNote = { text: string; isError: boolean }

declare module 'claude-code' {
  interface PluginState {
    taskboard: { board: Shaped<Board | null>; sync: SyncState; workers: Shaped<Worker[]>; expanded: string[]; folded: string[]; filter: string[]; overview: Shaped<Overview | null>; overviewState: OverviewState; enabled: boolean; cleanupNote: CleanupNote | null }
  }
}
