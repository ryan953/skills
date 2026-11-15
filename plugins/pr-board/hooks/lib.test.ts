import { describe, expect, test } from 'claude-code/testing'

import { ANSWER } from './fixture'
import {
  actionsFor,
  classifyAuthor,
  isHidden,
  isProjectForRepo,
  matchesFilter,
  parseCwd,
  parseFilter,
  parseQueries,
  parseSearch,
  pruneHidden,
  searchArgv,
  sessionIdOf,
  snooze,
  urlPattern,
} from './lib'

const NOW = Date.parse('2026-11-15T12:00:00Z')
const DAY = 24 * 60 * 60 * 1000
const { prs } = parseSearch(ANSWER)
const byNumber = (n: number) => {
  const pr = prs.find(p => p.number === n)
  if (pr === undefined) throw new Error(`no #${n}`)
  return pr
}

describe('queries', () => {
  test('the option splits on semicolons and falls back to mine + review requests', async () => {
    expect(parseQueries('author:@me;  org:getsentry label:x ; ')).toEqual([
      'author:@me',
      'org:getsentry label:x',
    ])
    expect(parseQueries('')).toEqual(['author:@me', 'review-requested:@me'])
  })

  test('each search is a variable, scoped to open PRs', async () => {
    const argv = searchArgv(['author:@me', 'label:"needs review"'])
    expect(argv.slice(0, 2)).toEqual(['api', 'graphql'])
    expect(argv).toContain('q1=is:pr is:open archived:false label:"needs review"')
    expect(argv.find(a => a.startsWith('query='))).toContain('q1: search(query: $q1')
  })
})

describe('parsing', () => {
  test('searches are merged and de-duplicated', async () => {
    expect(prs.map(p => p.number).sort()).toEqual([101, 202, 33].sort())
  })

  test('authors split into mine, bots and other people', async () => {
    expect(byNumber(101).authorKind).toBe('mine')
    expect(byNumber(202).authorKind).toBe('bot')
    expect(byNumber(202).author).toBe('dependabot[bot]')
    expect(byNumber(33).authorKind).toBe('other')
    expect(classifyAuthor('me', 'someone', 'User', 'seer/fix-it')).toBe('bot')
    expect(classifyAuthor('me', 'me', 'User', 'seer/fix-it')).toBe('mine')
  })

  test('CI, review, drafts, labels and threads come through', async () => {
    const mine = byNumber(101)
    expect(mine.ci).toBe('fail')
    expect(mine.unresolved).toBe(1)
    expect(mine.labels).toEqual([{ name: 'Scope: Frontend', color: 'd73a4a' }])
    expect(byNumber(202).isDraft).toBe(true)
    expect(byNumber(202).ci).toBe('pending')
    expect(byNumber(33).review).toBe('approved')
    expect(byNumber(33).mergeState).toBe('DIRTY')
  })
})

describe('filter', () => {
  const visible = (text: string) =>
    prs.filter(p => matchesFilter(p, parseFilter(text))).map(p => p.number).sort()

  test('a bare word searches title, repo, branch and author', async () => {
    expect(visible('react')).toEqual([202])
    expect(visible('relay')).toEqual([33])
    expect(visible('alice')).toEqual([33])
    expect(visible('#101')).toEqual([101])
  })

  test('keys narrow on one field and a dash negates', async () => {
    expect(visible('ci:fail')).toEqual([101])
    expect(visible('is:draft')).toEqual([202])
    expect(visible('-is:draft repo:getsentry/sentry')).toEqual([101])
    expect(visible('label:"scope: frontend"')).toEqual([101])
    expect(visible('-label:frontend')).toEqual([202, 33].sort())
    expect(visible('is:conflicts')).toEqual([33])
    expect(visible('')).toEqual([101, 202, 33].sort())
  })
})

describe('hiding', () => {
  test('a snooze hides until its time', async () => {
    const pr = byNumber(33)
    const hidden = { [pr.url]: snooze(pr, 'day', NOW) }
    expect(isHidden(pr, hidden, NOW + DAY / 2)).toBe(true)
    expect(isHidden(pr, hidden, NOW + DAY + 1)).toBe(false)
  })

  test('"until it changes" lifts when GitHub updatedAt moves', async () => {
    const pr = byNumber(33)
    const hidden = { [pr.url]: snooze(pr, 'change', NOW) }
    expect(isHidden(pr, hidden, NOW + 30 * DAY)).toBe(true)
    expect(isHidden({ ...pr, updatedAt: '2026-11-16T00:00:00Z' }, hidden, NOW)).toBe(false)
  })

  test('pruning drops lifted snoozes and keeps unseen ones for a month', async () => {
    const pr = byNumber(33)
    const gone = 'https://github.com/x/y/pull/9'
    const hidden = {
      [pr.url]: snooze(pr, 'day', NOW - 2 * DAY),
      [gone]: { title: 'gone', at: NOW - DAY, updatedAt: 'x' },
    }
    expect(Object.keys(pruneHidden(hidden, prs, NOW))).toEqual([gone])
    expect(Object.keys(pruneHidden(hidden, prs, NOW + 40 * DAY))).toEqual([])
  })
})

describe('actions', () => {
  const all = ['approve-pr', 'merge-pr', 'getsentry-tests']

  test('approve is for other people’s PRs I have not approved', async () => {
    expect(actionsFor(byNumber(101), all).canApprove).toBe(false)
    expect(actionsFor(byNumber(33), all).canApprove).toBe(true)
    expect(actionsFor({ ...byNumber(33), myReview: 'APPROVED' }, all).canApprove).toBe(false)
  })

  test('merge skips drafts; getsentry tests is sentry-only and once', async () => {
    expect(actionsFor(byNumber(202), all).canMerge).toBe(false)
    expect(actionsFor(byNumber(101), all).canTestLabel).toBe(true)
    expect(actionsFor(byNumber(33), all).canTestLabel).toBe(false)
    const labelled = {
      ...byNumber(101),
      labels: [{ name: 'Trigger: getsentry tests', color: '' }],
    }
    expect(actionsFor(labelled, all).canTestLabel).toBe(false)
  })

  test('a button shows only when its skill is installed', async () => {
    expect(actionsFor(byNumber(33), []).canApprove).toBe(false)
    expect(actionsFor(byNumber(101), ['merge-pr']).canTestLabel).toBe(false)
  })
})

describe('finding a conversation', () => {
  test('the URL pattern does not match a longer PR number', async () => {
    const re = new RegExp(urlPattern(byNumber(101)))
    expect(re.test('see https://github.com/getsentry/sentry/pull/101"')).toBe(true)
    expect(re.test('https://github.com/getsentry/sentry/pull/101')).toBe(true)
    expect(re.test('https://github.com/getsentry/sentry/pull/1012')).toBe(false)
  })

  test('branch hits count only in a project dir for that repo', async () => {
    expect(isProjectForRepo('/h/.claude/projects/-Users-me-code-sentry', 'getsentry/sentry')).toBe(true)
    expect(
      isProjectForRepo('/h/.claude/projects/-Users-me-code-sentry--claude-worktrees-x', 'getsentry/sentry'),
    ).toBe(true)
    expect(isProjectForRepo('/h/.claude/projects/-Users-me-code-sentry-docs', 'getsentry/sentry')).toBe(true)
    expect(isProjectForRepo('/h/.claude/projects/-Users-me-code-relay', 'getsentry/sentry')).toBe(false)
  })

  test('session id and cwd come out of the transcript', async () => {
    expect(sessionIdOf('/p/-x/0b1c-22.jsonl')).toBe('0b1c-22')
    expect(parseCwd('"cwd":"/Users/me/code/sen\\"try"')).toBe('/Users/me/code/sen"try')
    expect(parseCwd('')).toBe(undefined)
  })
})
