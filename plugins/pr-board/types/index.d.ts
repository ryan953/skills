export type AuthorKind = 'mine' | 'bot' | 'other'
export type CiState = 'pass' | 'fail' | 'pending' | 'none'
export type ReviewState = 'approved' | 'changes' | 'required' | 'none'

export type Label = { name: string; color: string }

export type Pr = {
  url: string
  repo: string
  number: number
  title: string
  author: string
  authorKind: AuthorKind
  isDraft: boolean
  branch: string
  labels: Label[]
  ci: CiState
  review: ReviewState
  /** My own latest opinionated review, when I left one. */
  myReview?: 'APPROVED' | 'CHANGES_REQUESTED' | 'COMMENTED' | 'DISMISSED' | 'PENDING'
  /** GitHub's mergeStateStatus: CLEAN, BLOCKED, BEHIND, DIRTY, UNSTABLE, ... */
  mergeState: string
  isAutoMerge: boolean
  additions: number
  deletions: number
  files: number
  unresolved: number
  createdAt: string
  updatedAt: string
}

/**
 * A snoozed PR. `until` hides it until that time; `updatedAt` hides it until
 * GitHub's updatedAt moves (a push, comment, review or label).
 */
export type Hidden = {
  title: string
  at: number
  until?: number
  updatedAt?: string
}
export type HiddenMap = Record<string, Hidden>

export type Meta = {
  isLoading: boolean
  loadedAt?: number
  error?: string
  me?: string
}

export type Group = 'mine' | 'bot' | 'other'

declare module 'claude-code' {
  interface PluginState {
    'pr-board': {
      prs: Shaped<Pr[]>
      meta: Shaped<Meta>
      hidden: Shaped<HiddenMap>
      filter: string
      expanded: string
      collapsed: Shaped<Group[]>
      showHidden: boolean
      commands: Shaped<string[]>
      notice: string
    }
  }
}
