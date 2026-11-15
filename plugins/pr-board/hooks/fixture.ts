// A gh GraphQL answer shaped like searchArgv's query, for the tests.

const pr = (over: Record<string, unknown>) => ({
  number: 1,
  title: 'A change',
  url: 'https://github.com/getsentry/sentry/pull/1',
  isDraft: false,
  createdAt: '2026-11-10T00:00:00Z',
  updatedAt: '2026-11-14T00:00:00Z',
  headRefName: 'feat/x',
  additions: 10,
  deletions: 2,
  changedFiles: 3,
  repository: { nameWithOwner: 'getsentry/sentry' },
  author: { __typename: 'User', login: 'me' },
  labels: { nodes: [] },
  reviewDecision: 'REVIEW_REQUIRED',
  mergeStateStatus: 'BLOCKED',
  autoMergeRequest: null,
  viewerLatestReview: null,
  reviewThreads: { nodes: [] },
  commits: { nodes: [{ commit: { statusCheckRollup: { state: 'SUCCESS' } } }] },
  ...over,
})

export const MINE = pr({
  number: 101,
  title: 'feat(issues): Add a stream filter',
  url: 'https://github.com/getsentry/sentry/pull/101',
  labels: { nodes: [{ name: 'Scope: Frontend', color: 'd73a4a' }] },
  commits: { nodes: [{ commit: { statusCheckRollup: { state: 'FAILURE' } } }] },
  reviewThreads: { nodes: [{ isResolved: false }, { isResolved: true }] },
})

export const BOT = pr({
  number: 202,
  title: 'chore(deps): Bump react from 19.0.0 to 19.1.0',
  url: 'https://github.com/getsentry/sentry/pull/202',
  author: { __typename: 'Bot', login: 'dependabot' },
  headRefName: 'dependabot/npm/react',
  isDraft: true,
  commits: { nodes: [{ commit: { statusCheckRollup: { state: 'PENDING' } } }] },
})

export const OTHER = pr({
  number: 33,
  title: 'fix(relay): Drop stale spans',
  url: 'https://github.com/getsentry/relay/pull/33',
  repository: { nameWithOwner: 'getsentry/relay' },
  author: { __typename: 'User', login: 'alice' },
  reviewDecision: 'APPROVED',
  mergeStateStatus: 'DIRTY',
  updatedAt: '2026-11-15T00:00:00Z',
})

export function answer(...searches: unknown[][]): string {
  const data: Record<string, unknown> = { viewer: { login: 'me' } }
  searches.forEach((nodes, i) => {
    data[`q${i}`] = { nodes }
  })

  return JSON.stringify({ data })
}

// The second search repeats MINE: the board lists it once.
export const ANSWER = answer([MINE, BOT], [OTHER, MINE])
