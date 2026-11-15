// Pure logic for pr-board: the GitHub query, turning its answer into rows,
// filtering, snoozing and session lookup helpers. No `$` here, so
// lib.test.ts covers it without an engine.

import type {
  AuthorKind,
  CiState,
  Group,
  Hidden,
  HiddenMap,
  Label,
  Pr,
  ReviewState,
} from '../types'

export const GETSENTRY_REPO = 'getsentry/sentry'
// The label getsentry's dispatch workflow listens for; approve-pr uses the same.
export const GETSENTRY_LABEL = 'Trigger: getsentry tests'

// ---------------------------------------------------------------------------
// Query

const FIELDS = `
  number title url isDraft createdAt updatedAt headRefName
  additions deletions changedFiles
  repository { nameWithOwner }
  author { __typename login }
  labels(first: 20) { nodes { name color } }
  reviewDecision mergeStateStatus
  autoMergeRequest { enabledAt }
  viewerLatestReview { state }
  reviewThreads(first: 100) { nodes { isResolved } }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
`

/** Splits the `queries` option ("author:@me; review-requested:@me"). */
export function parseQueries(option: string | undefined): string[] {
  const list = (option ?? '')
    .split(/[;\n]/)
    .map(q => q.trim())
    .filter(Boolean)

  return list.length > 0 ? list : ['author:@me', 'review-requested:@me']
}

/**
 * One GraphQL request for every search, each an alias, passed as variables so
 * a query's quotes never need escaping. Returns gh's argv after `gh`.
 */
export function searchArgv(queries: readonly string[], perQuery = 50): string[] {
  const vars = queries.map((_, i) => `$q${i}: String!`).join(', ')
  const searches = queries
    .map(
      (_, i) =>
        `q${i}: search(query: $q${i}, type: ISSUE, first: ${perQuery}) { nodes { ... on PullRequest { ${FIELDS} } } }`,
    )
    .join('\n')
  const query = `query(${vars}) { viewer { login }\n${searches}\n}`
  const argv = ['api', 'graphql', '-f', `query=${query}`]
  queries.forEach((q, i) => {
    argv.push('-f', `q${i}=is:pr is:open archived:false ${q}`)
  })

  return argv
}

// ---------------------------------------------------------------------------
// Parsing

// Automation that pushes through ordinary user accounts, and the branch
// prefixes bots use. Mirrors classify_author in approve-pr's lib.sh.
const BOT_LOGINS = new Set([
  'seer-by-sentry',
  'sentry-autofix',
  'dependabot',
  'renovate',
  'github-actions',
  'getsantry',
])
const BOT_BRANCH = /^(seer|autofix|renovate|dependabot|cursor|copilot)\//

export function classifyAuthor(
  me: string,
  login: string,
  typename: string,
  branch: string,
): AuthorKind {
  if (me !== '' && login === me) return 'mine'
  if (typename === 'Bot') return 'bot'
  if (login.endsWith('[bot]') || BOT_LOGINS.has(login)) return 'bot'
  if (BOT_BRANCH.test(branch)) return 'bot'

  return 'other'
}

export function ciState(rollup: string | null | undefined): CiState {
  switch (rollup) {
    case 'SUCCESS':
      return 'pass'
    case 'FAILURE':
    case 'ERROR':
      return 'fail'
    case 'PENDING':
    case 'EXPECTED':
      return 'pending'
    default:
      return 'none'
  }
}

export function reviewState(decision: string | null | undefined): ReviewState {
  switch (decision) {
    case 'APPROVED':
      return 'approved'
    case 'CHANGES_REQUESTED':
      return 'changes'
    case 'REVIEW_REQUIRED':
      return 'required'
    default:
      return 'none'
  }
}

type Node = Record<string, any>

/** gh's JSON answer → my login and the PRs, de-duplicated across searches. */
export function parseSearch(json: string): { me: string; prs: Pr[] } {
  const data = JSON.parse(json)?.data
  if (data == null) throw new Error('GitHub answered no data')
  const me: string = data.viewer?.login ?? ''
  const seen = new Map<string, Pr>()

  for (const [key, value] of Object.entries<Node>(data)) {
    if (!/^q\d+$/.test(key)) continue
    for (const node of (value?.nodes ?? []) as Node[]) {
      if (node == null || typeof node.url !== 'string' || seen.has(node.url)) continue
      seen.set(node.url, toPr(node, me))
    }
  }

  return { me, prs: [...seen.values()] }
}

function toPr(n: Node, me: string): Pr {
  const login: string = n.author?.login ?? 'ghost'
  const typename: string = n.author?.__typename ?? ''
  const branch: string = n.headRefName ?? ''
  const labels: Label[] = (n.labels?.nodes ?? []).map((l: Node) => ({
    name: String(l.name),
    color: String(l.color ?? ''),
  }))
  const threads: Node[] = n.reviewThreads?.nodes ?? []
  const pr: Pr = {
    url: n.url,
    repo: n.repository?.nameWithOwner ?? '',
    number: Number(n.number),
    title: String(n.title ?? ''),
    // GraphQL drops the `[bot]` suffix GitHub shows for App authors.
    author: typename === 'Bot' && !login.endsWith('[bot]') ? `${login}[bot]` : login,
    authorKind: classifyAuthor(me, login, typename, branch),
    isDraft: n.isDraft === true,
    branch,
    labels,
    ci: ciState(n.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state),
    review: reviewState(n.reviewDecision),
    mergeState: String(n.mergeStateStatus ?? 'UNKNOWN'),
    isAutoMerge: n.autoMergeRequest != null,
    additions: Number(n.additions ?? 0),
    deletions: Number(n.deletions ?? 0),
    files: Number(n.changedFiles ?? 0),
    unresolved: threads.filter(t => t && t.isResolved === false).length,
    createdAt: String(n.createdAt ?? ''),
    updatedAt: String(n.updatedAt ?? ''),
  }
  const mine = n.viewerLatestReview?.state
  if (typeof mine === 'string') pr.myReview = mine as Pr['myReview']

  return pr
}

// ---------------------------------------------------------------------------
// Filtering

export type Token = { key?: string; value: string; isNegated: boolean }

/**
 * `ci:fail -label:"needs triage" repo:sentry fix` → tokens. A bare word
 * matches the title, repo, branch, author or #number; `key:value` narrows on
 * one field; a leading `-` negates. Quotes keep spaces.
 */
export function parseFilter(text: string): Token[] {
  const tokens: Token[] = []
  const re = /(-?)(?:([a-z]+):)?(?:"([^"]*)"?|(\S+))/gi
  for (const m of text.matchAll(re)) {
    const value = (m[3] ?? m[4] ?? '').toLowerCase()
    if (value === '' && m[2] === undefined) continue
    tokens.push({
      key: m[2]?.toLowerCase(),
      value,
      isNegated: m[1] === '-',
    })
  }

  return tokens
}

function has(haystack: string, needle: string): boolean {
  return haystack.toLowerCase().includes(needle)
}

function tokenMatches(pr: Pr, t: Token): boolean {
  const v = t.value
  switch (t.key) {
    case undefined:
      return (
        has(pr.title, v) ||
        has(pr.repo, v) ||
        has(pr.branch, v) ||
        has(pr.author, v) ||
        `#${pr.number}` === v ||
        String(pr.number) === v
      )
    case 'repo':
      return has(pr.repo, v)
    case 'author':
    case 'by':
      return has(pr.author, v)
    case 'label':
      return pr.labels.some(l => has(l.name, v))
    case 'ci':
      return pr.ci === v || (v === 'red' && pr.ci === 'fail') || (v === 'green' && pr.ci === 'pass')
    case 'review':
      return pr.review === v
    case 'branch':
      return has(pr.branch, v)
    case 'is':
      switch (v) {
        case 'draft':
          return pr.isDraft
        case 'ready':
          return !pr.isDraft
        case 'approved':
          return pr.review === 'approved'
        case 'automerge':
          return pr.isAutoMerge
        case 'conflict':
        case 'conflicts':
          return pr.mergeState === 'DIRTY'
        case 'mine':
        case 'bot':
        case 'other':
          return pr.authorKind === v
        case 'unreviewed':
          return pr.myReview === undefined
        default:
          return false
      }
    default:
      // An unknown key reads as plain text, so `fix:` still finds a title.
      return has(pr.title, `${t.key}:${v}`)
  }
}

export function matchesFilter(pr: Pr, tokens: readonly Token[]): boolean {
  return tokens.every(t => tokenMatches(pr, t) !== t.isNegated)
}

// ---------------------------------------------------------------------------
// Snoozing

export type SnoozeKind = 'day' | 'week' | 'change'

export function snooze(pr: Pr, kind: SnoozeKind, now: number): Hidden {
  const base = { title: pr.title, at: now }
  if (kind === 'change') return { ...base, updatedAt: pr.updatedAt }
  const days = kind === 'day' ? 1 : 7

  return { ...base, until: now + days * 24 * 60 * 60 * 1000 }
}

export function isHidden(pr: Pr, hidden: HiddenMap, now: number): boolean {
  const h = hidden[pr.url]
  if (h === undefined) return false
  if (h.until !== undefined && now < h.until) return true
  if (h.updatedAt !== undefined && h.updatedAt === pr.updatedAt) return true

  return false
}

const KEEP_UNSEEN_MS = 30 * 24 * 60 * 60 * 1000

/**
 * Drops snoozes that no longer hide anything: a time that passed, a PR that
 * changed, or a PR missing from the list for a month (closed or merged).
 */
export function pruneHidden(hidden: HiddenMap, prs: readonly Pr[], now: number): HiddenMap {
  const byUrl = new Map(prs.map(p => [p.url, p]))
  const kept: HiddenMap = {}
  for (const [url, h] of Object.entries(hidden)) {
    const pr = byUrl.get(url)
    if (pr === undefined) {
      if (now - h.at < KEEP_UNSEEN_MS) kept[url] = h
      continue
    }
    if (isHidden(pr, hidden, now)) kept[url] = h
  }

  return kept
}

export function describeHidden(h: Hidden, now: number): string {
  if (h.until !== undefined) return `snoozed, back in ${age(h.until - now)}`

  return 'hidden until it changes'
}

// ---------------------------------------------------------------------------
// Grouping and display

export const GROUPS: readonly { id: Group; title: string }[] = [
  { id: 'mine', title: 'Mine' },
  { id: 'other', title: 'Other people' },
  { id: 'bot', title: 'Bots' },
]

export function sortPrs(prs: readonly Pr[]): Pr[] {
  return [...prs].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
}

export function age(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  const m = Math.round(s / 60)
  if (m < 60) return `${m}m`
  const h = Math.round(m / 60)
  if (h < 48) return `${h}h`
  const d = Math.round(h / 24)
  if (d < 60) return `${d}d`

  return `${Math.round(d / 30)}mo`
}

export function since(iso: string, now: number): string {
  const t = Date.parse(iso)

  return Number.isNaN(t) ? '?' : age(now - t)
}

export const CI_MARK: Record<CiState, string> = {
  pass: '✓ CI',
  fail: '✗ CI',
  pending: '● CI',
  none: '– CI',
}

export const REVIEW_TEXT: Record<ReviewState, string> = {
  approved: 'approved',
  changes: 'changes requested',
  required: 'needs review',
  none: '',
}

export function mergeNote(state: string): string {
  switch (state) {
    case 'DIRTY':
      return 'conflicts'
    case 'BEHIND':
      return 'behind base'
    case 'BLOCKED':
      return 'blocked'
    case 'UNSTABLE':
      return 'checks failing'
    case 'CLEAN':
      return 'ready to merge'
    default:
      return ''
  }
}

/** GitHub label colors are bare hex; anything else draws in the default color. */
export function labelColor(color: string): string | undefined {
  return /^[0-9a-f]{6}$/i.test(color) ? `#${color}` : undefined
}

export function short(repo: string): string {
  return repo.slice(repo.indexOf('/') + 1)
}

/** Which action buttons apply to a PR, given the slash commands installed. */
export function actionsFor(pr: Pr, commands: readonly string[]): {
  canApprove: boolean
  canMerge: boolean
  canTestLabel: boolean
} {
  const installed = new Set(commands)

  return {
    canApprove:
      installed.has('approve-pr') && pr.authorKind !== 'mine' && pr.myReview !== 'APPROVED',
    canMerge: installed.has('merge-pr') && !pr.isDraft,
    canTestLabel:
      installed.has('getsentry-tests') &&
      pr.repo === GETSENTRY_REPO &&
      !pr.labels.some(l => l.name === GETSENTRY_LABEL),
  }
}

// ---------------------------------------------------------------------------
// Finding a conversation about a PR

export function escapeRegex(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/** An extended regex for grep matching the PR's URL and not a longer number. */
export function urlPattern(pr: Pr): string {
  return `github\\.com/${escapeRegex(pr.repo)}/pull/${pr.number}([^0-9]|$)`
}

/**
 * Claude Code keeps a session under ~/.claude/projects/<cwd, / and . as ->/.
 * A branch-name hit only counts in a project dir for this repo (or one of its
 * worktrees), since branch names repeat across repositories.
 */
export function isProjectForRepo(projectDir: string, repo: string): boolean {
  const name = short(repo).replace(/[^a-zA-Z0-9]/g, '-')
  const dir = projectDir.slice(projectDir.lastIndexOf('/') + 1)

  return dir.endsWith(`-${name}`) || dir.includes(`-${name}-`)
}

/** Session id from a transcript path: its file name without `.jsonl`. */
export function sessionIdOf(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1).replace(/\.jsonl$/, '')
}

/** The first `"cwd":"…"` grep -o found, decoded as the JSON string it is. */
export function parseCwd(line: string): string | undefined {
  const m = line.match(/"cwd":("(?:[^"\\]|\\.)*")/)
  if (m?.[1] === undefined) return undefined
  try {
    return JSON.parse(m[1]) as string
  } catch {
    return undefined
  }
}

export function chatPrompt(pr: Pr): string {
  return `Let's talk about ${pr.url} ("${pr.title}"). Look it up with gh and give me a quick rundown of where it stands: CI, reviews, unresolved threads and what's left to do.`
}

export function groupCounts(prs: readonly Pr[]): Record<Group, number> {
  const counts: Record<Group, number> = { mine: 0, bot: 0, other: 0 }
  for (const pr of prs) counts[pr.authorKind] += 1

  return counts
}
