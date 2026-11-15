import { atom, read, update } from 'claude-code'
import type { EngineInterface, PluginOptions, RenderSurface, Register } from 'claude-code'

import type { Group, HiddenMap, Meta, Pr } from '../types'
import {
  CI_MARK,
  GROUPS,
  REVIEW_TEXT,
  actionsFor,
  age,
  chatPrompt,
  describeHidden,
  groupCounts,
  isHidden,
  isProjectForRepo,
  labelColor,
  matchesFilter,
  mergeNote,
  parseCwd,
  parseFilter,
  parseQueries,
  parseSearch,
  pruneHidden,
  searchArgv,
  sessionIdOf,
  short,
  since,
  snooze,
  sortPrs,
  urlPattern,
  type SnoozeKind,
} from './lib'

type $ = EngineInterface

const PANE = 'pr-board'
const TITLE = 'Pull requests'
const STORE_HIDDEN = 'hidden'

// Change a tag when that value's fields change: it declines what an earlier
// version stored, which outlives a reload.
const prsAtom = atom({ plugin: 'pr-board', key: 'prs' } as const, [], { shape: 'prs-1' })
const metaAtom = atom({ plugin: 'pr-board', key: 'meta' } as const, { isLoading: false }, {
  shape: 'meta-1',
})
const hiddenAtom = atom({ plugin: 'pr-board', key: 'hidden' } as const, {}, { shape: 'hidden-1' })
const filterAtom = atom({ plugin: 'pr-board', key: 'filter' } as const, '')
const expandedAtom = atom({ plugin: 'pr-board', key: 'expanded' } as const, '')
const collapsedAtom = atom({ plugin: 'pr-board', key: 'collapsed' } as const, [], {
  shape: 'collapsed-1',
})
const showHiddenAtom = atom({ plugin: 'pr-board', key: 'showHidden' } as const, false)
const commandsAtom = atom({ plugin: 'pr-board', key: 'commands' } as const, [], {
  shape: 'commands-1',
})
const noticeAtom = atom({ plugin: 'pr-board', key: 'notice' } as const, '')

// Set when a skill button queued a command: the turn it runs in may change a
// PR (approved, merged, labelled), so the list refreshes when that turn ends.
let refreshAfterTurn = false

// ---------------------------------------------------------------------------
// Host commands

// GUI launches (the desktop app) can start without the login shell's PATH,
// which is where Homebrew puts gh and tmux.
const PREFIXES = ['', '/opt/homebrew/bin/', '/usr/local/bin/', '/usr/bin/']
const resolved = new Map<string, string>()

async function run(
  $: $,
  tool: string,
  args: readonly string[],
  init?: { cwd?: string; timeoutMs?: number },
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  const known = resolved.get(tool)
  const tries = known !== undefined ? [known] : PREFIXES.map(p => `${p}${tool}`)
  let lastError: unknown
  for (const bin of tries) {
    try {
      const out = await $.process.run([bin, ...args], init)
      resolved.set(tool, bin)
      return out
    } catch (error) {
      lastError = error
    }
  }
  throw new Error(`${tool} not found (${String(lastError)})`)
}

function firstLine(text: string): string {
  return text.trim().split('\n')[0]?.slice(0, 200) ?? ''
}

function sq(text: string): string {
  return `'${text.replace(/'/g, `'\\''`)}'`
}

// ---------------------------------------------------------------------------
// Loading

async function refresh($: $, options: PluginOptions): Promise<void> {
  const meta = await read($, metaAtom)
  if (meta.isLoading) return
  await update($, metaAtom, m => ({ ...m, isLoading: true }))
  const queries = parseQueries(typeof options.queries === 'string' ? options.queries : undefined)
  let next: Meta
  try {
    const out = await run($, 'gh', searchArgv(queries), { timeoutMs: 60_000 })
    if (out.exitCode !== 0) throw new Error(firstLine(out.stderr) || `gh exited ${out.exitCode}`)
    const { me, prs } = parseSearch(out.stdout)
    const now = await $.clock.now()
    await update($, prsAtom, () => sortPrs(prs))
    const hidden = pruneHidden(await read($, hiddenAtom), prs, now)
    await saveHidden($, hidden)
    next = { isLoading: false, loadedAt: now, me }
  } catch (error) {
    next = { ...(await read($, metaAtom)), isLoading: false, error: String(error) }
  }
  if (next.error === undefined) delete next.error
  await update($, metaAtom, () => next)
}

async function saveHidden($: $, hidden: HiddenMap): Promise<void> {
  await update($, hiddenAtom, () => hidden)
  await $.store.set(STORE_HIDDEN, hidden)
}

async function loadCommands($: $): Promise<void> {
  const names = (await $.command.list()).map(c => c.name)
  await update($, commandsAtom, () => names)
}

// ---------------------------------------------------------------------------
// Actions

async function say($: $, text: string): Promise<void> {
  $.ui.toast(text)
  await update($, noticeAtom, () => '')
}

async function openOnGitHub($: $, pr: Pr, surface: RenderSurface): Promise<void> {
  for (const opener of ['open', 'xdg-open']) {
    try {
      const out = await run($, opener, [pr.url], { timeoutMs: 10_000 })
      if (out.exitCode === 0) return
    } catch {
      // try the next opener
    }
  }
  const copied = await $.ui.copy({ text: pr.url, surface })
  await say($, copied.isCopied ? `Couldn't open a browser; copied ${pr.url}` : pr.url)
}

type Found = { sessionId: string; cwd: string }

/**
 * The newest saved conversation that mentions the PR's URL, or that ran on
 * its branch in a checkout of its repo. Not this session.
 */
async function findConversation($: $, pr: Pr): Promise<Found | undefined> {
  const home = (await $.env.get('HOME')) ?? ''
  const config = (await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${home}/.claude`
  const projects = `${config}/projects`
  if (!(await $.fs.exists(projects))) return undefined
  const current = await $.session.id()

  const grep = async (args: string[]): Promise<string[]> => {
    const out = await run($, 'grep', ['-rl', '--include=*.jsonl', ...args, projects], {
      timeoutMs: 30_000,
    })
    return out.stdout.split('\n').filter(Boolean)
  }

  const hits = new Set(await grep(['-E', urlPattern(pr)]))
  if (pr.branch !== '' && !/^(main|master)$/.test(pr.branch)) {
    for (const file of await grep(['-F', `"gitBranch":"${pr.branch}"`])) {
      if (isProjectForRepo(file.slice(0, file.lastIndexOf('/')), pr.repo)) hits.add(file)
    }
  }
  const files = [...hits].filter(f => sessionIdOf(f) !== current)
  if (files.length === 0) return undefined

  const sorted = await run($, 'ls', ['-t', '--', ...files])
  for (const file of sorted.stdout.split('\n').filter(Boolean)) {
    const line = await run($, 'grep', ['-m1', '-oE', '"cwd":"([^"\\\\]|\\\\.)*"', file])
    const cwd = parseCwd(line.stdout)
    if (cwd !== undefined && (await $.fs.exists(cwd))) return { sessionId: sessionIdOf(file), cwd }
  }

  return undefined
}

/** A local clone of the PR's repo under one of the code roots, else home. */
async function findClone($: $, pr: Pr, options: PluginOptions): Promise<string> {
  const home = (await $.env.get('HOME')) ?? '/'
  const raw = typeof options.codeRoots === 'string' ? options.codeRoots : '~/code'
  const roots = raw
    .split(/[;,]/)
    .map(r => r.trim().replace(/^~(?=\/|$)/, home))
    .filter(Boolean)
  const [owner, name] = pr.repo.split('/')
  for (const root of roots) {
    for (const dir of [`${root}/${name}`, `${root}/${owner}/${name}`]) {
      if (await $.fs.exists(`${dir}/.git`)) return dir
    }
  }

  return home
}

async function tmuxSocket($: $): Promise<string | undefined> {
  const inherited = await $.env.get('TMUX')
  const candidates: string[] = []
  if (inherited) candidates.push(inherited.split(',')[0] ?? '')
  try {
    const uid = (await run($, 'id', ['-u'])).stdout.trim()
    const tmp = (await $.env.get('TMUX_TMPDIR')) ?? '/tmp'
    for (const dir of [tmp, '/tmp', '/private/tmp']) candidates.push(`${dir}/tmux-${uid}/default`)
  } catch {
    // no `id`: only an inherited socket
  }
  for (const socket of candidates) {
    if (socket === '') continue
    try {
      if ((await run($, 'tmux', ['-S', socket, 'list-sessions'])).exitCode === 0) return socket
    } catch {
      return undefined
    }
  }

  return undefined
}

async function openChat(
  $: $,
  pr: Pr,
  surface: RenderSurface,
  options: PluginOptions,
): Promise<void> {
  await update($, noticeAtom, () => `Looking for a conversation about #${pr.number}…`)
  const found = await findConversation($, pr)
  const cwd = found?.cwd ?? (await findClone($, pr, options))
  const argv = found ? ['claude', '--resume', found.sessionId] : ['claude', chatPrompt(pr)]
  const what = found ? `Resumed ${found.sessionId.slice(0, 8)}` : 'Started a new chat'
  const name = `pr: ${short(pr.repo)}#${pr.number}`

  const socket = await tmuxSocket($)
  if (socket !== undefined) {
    const out = await run($, 'tmux', ['-S', socket, 'new-window', '-c', cwd, '-n', name, '--', ...argv])
    if (out.exitCode === 0) {
      await say($, `${what} for #${pr.number} in tmux window "${name}"`)
      return
    }
  }
  const command = `cd ${sq(cwd)} && ${argv.map(sq).join(' ')}`
  const copied = await $.ui.copy({ text: command, surface })
  await update($, noticeAtom, () =>
    copied.isCopied
      ? `No tmux server; copied a command to ${found ? 'resume' : 'start'} the chat. Paste it in a terminal.`
      : `Run in a terminal: ${command}`,
  )
}

async function runSkill($: $, command: string, pr: Pr): Promise<void> {
  refreshAfterTurn = true
  $.ui.toast(`Running /${command} for #${pr.number}`)
  try {
    await $.command.run({ command, args: pr.url })
  } catch (error) {
    await update($, noticeAtom, () => `/${command} didn't run: ${String(error)}`)
  }
}

async function hide($: $, pr: Pr, kind: SnoozeKind): Promise<void> {
  const now = await $.clock.now()
  const hidden = { ...(await read($, hiddenAtom)), [pr.url]: snooze(pr, kind, now) }
  await saveHidden($, hidden)
  await update($, expandedAtom, () => '')
}

async function unhide($: $, url: string): Promise<void> {
  const { [url]: _gone, ...rest } = await read($, hiddenAtom)
  await saveHidden($, rest)
}

// ---------------------------------------------------------------------------

export const register: Register = (on, options) => {
  const refreshMinutes = Number(options.refreshMinutes ?? 5)

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({
      name: 'prs',
      description: 'Show open pull requests: mine, other people’s, and bots’',
      argumentHint: '[filter]',
    })
    const stored = (await $.store.get(STORE_HIDDEN)) as HiddenMap | undefined
    if (stored && typeof stored === 'object') await update($, hiddenAtom, () => stored)
    void loadCommands($)
    void refresh($, options)
    if (refreshMinutes > 0) $.clock.every(refreshMinutes * 60_000, () => void refresh($, options))

    return started
  })

  on('command.run', { command: 'prs' }, async ($, e) => {
    const filter = (e.args ?? '').trim()
    if (filter !== '') await update($, filterAtom, () => filter)
    await $.ui.open({ id: PANE, title: TITLE })
    void loadCommands($)
    const meta = await read($, metaAtom)
    const now = await $.clock.now()
    if (meta.loadedAt === undefined || now - meta.loadedAt > 60_000) void refresh($, options)

    return { text: filter ? `Pull requests pane opened, filtered by "${filter}".` : 'Pull requests pane opened.' }
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (refreshAfterTurn) {
      refreshAfterTurn = false
      void refresh($, options)
    }

    return done
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Input, Link } = $.ui.resolve(e)
    const surface = e.surface
    const prs = await read($, prsAtom)
    const meta = await read($, metaAtom)
    const hidden = await read($, hiddenAtom)
    const filter = await read($, filterAtom)
    const expanded = await read($, expandedAtom)
    const collapsed = await read($, collapsedAtom)
    const showHidden = await read($, showHiddenAtom)
    const commands = await read($, commandsAtom)
    const notice = await read($, noticeAtom)
    const now = await $.clock.now()

    const live = prs.filter(pr => !isHidden(pr, hidden, now))
    const hiddenCount = prs.length - live.length
    const tokens = parseFilter(filter)
    const visible = live.filter(pr => matchesFilter(pr, tokens))

    const status = meta.isLoading
      ? 'loading…'
      : meta.loadedAt !== undefined
        ? `updated ${age(now - meta.loadedAt)} ago`
        : ''

    // A minimized pane on the desktop app: counts only, clicks may not land.
    if (e.props.placement === 'widget') {
      const counts = groupCounts(live)
      const red = live.filter(p => p.authorKind === 'mine' && p.ci === 'fail').length
      return (
        <Box flexDirection="column">
          <Text bold>PRs</Text>
          <Text>
            {counts.mine} mine · {counts.other} others · {counts.bot} bots
          </Text>
          {red > 0 && <Text color="error">{red} of mine failing CI</Text>}
        </Box>
      )
    }

    const statusLine = (pr: Pr) => {
      const review = REVIEW_TEXT[pr.review]
      const merge = mergeNote(pr.mergeState)
      const shown = pr.labels.slice(0, 4)
      return (
        <Box flexDirection="row" flexWrap="wrap" columnGap={1} paddingLeft={2}>
          <Text
            color={pr.ci === 'pass' ? 'success' : pr.ci === 'fail' ? 'error' : pr.ci === 'pending' ? 'warning' : undefined}
            dimColor={pr.ci === 'none'}
          >
            {CI_MARK[pr.ci]}
          </Text>
          {pr.isDraft ? <Text dimColor>draft</Text> : <Text>ready</Text>}
          {review !== '' && (
            <Text color={pr.review === 'approved' ? 'success' : pr.review === 'changes' ? 'error' : 'warning'}>
              {review}
            </Text>
          )}
          {pr.myReview === 'APPROVED' && pr.authorKind !== 'mine' && <Text color="success">✓ you</Text>}
          {merge !== '' && merge !== 'ready to merge' && pr.mergeState !== 'BLOCKED' && (
            <Text color={pr.mergeState === 'DIRTY' ? 'error' : 'warning'}>{merge}</Text>
          )}
          {pr.isAutoMerge && <Text color="merged">automerge</Text>}
          {pr.unresolved > 0 && <Text color="warning">{pr.unresolved} unresolved</Text>}
          <Text dimColor>
            +{pr.additions} −{pr.deletions}
          </Text>
          {pr.authorKind !== 'mine' && <Text dimColor>@{pr.author}</Text>}
          <Text dimColor>{since(pr.updatedAt, now)}</Text>
          {shown.map(l => (
            <Text>
              <Text color={labelColor(l.color)}>●</Text> {l.name}
            </Text>
          ))}
          {pr.labels.length > shown.length && <Text dimColor>+{pr.labels.length - shown.length} labels</Text>}
        </Box>
      )
    }

    const details = (pr: Pr) => {
      const { canApprove, canMerge, canTestLabel } = actionsFor(pr, commands)
      return (
        <Box flexDirection="column" paddingLeft={2} rowGap={0}>
          <Text dimColor wrap="wrap">
            {pr.repo} · {pr.branch} · @{pr.author} · opened {since(pr.createdAt, now)} ago · {pr.files} files
          </Text>
          {pr.labels.length > 4 && (
            <Box flexDirection="row" flexWrap="wrap" columnGap={1}>
              {pr.labels.map(l => (
                <Text>
                  <Text color={labelColor(l.color)}>●</Text> {l.name}
                </Text>
              ))}
            </Box>
          )}
          <Box flexDirection="row" flexWrap="wrap" columnGap={1}>
            {surface === 'mobile' ? (
              <Link href={pr.url} label="Open on GitHub" />
            ) : (
              <Button key={`open:${pr.url}`} variant="primary" onPress={p => void openOnGitHub($, pr, p.surface)}>
                Open on GitHub
              </Button>
            )}
            <Button key={`chat:${pr.url}`} onPress={p => void openChat($, pr, p.surface, options)}>
              Chat
            </Button>
            {canApprove && (
              <Button key={`approve:${pr.url}`} onPress={() => void runSkill($, 'approve-pr', pr)}>
                Approve
              </Button>
            )}
            {canMerge && (
              <Button key={`merge:${pr.url}`} onPress={() => void runSkill($, 'merge-pr', pr)}>
                Merge
              </Button>
            )}
            {canTestLabel && (
              <Button key={`gst:${pr.url}`} onPress={() => void runSkill($, 'getsentry-tests', pr)}>
                getsentry tests
              </Button>
            )}
          </Box>
          <Box flexDirection="row" flexWrap="wrap" columnGap={1}>
            <Text dimColor>Hide:</Text>
            <Button key={`hide-day:${pr.url}`} dimColor onPress={() => void hide($, pr, 'day')}>
              1 day
            </Button>
            <Button key={`hide-week:${pr.url}`} dimColor onPress={() => void hide($, pr, 'week')}>
              1 week
            </Button>
            <Button key={`hide-change:${pr.url}`} dimColor onPress={() => void hide($, pr, 'change')}>
              until it changes
            </Button>
          </Box>
        </Box>
      )
    }

    const row = (pr: Pr) => {
      const isOpen = expanded === pr.url
      return (
        <Box flexDirection="column">
          <Button
            key={`row:${pr.url}`}
            plain
            onPress={() => void update($, expandedAtom, cur => (cur === pr.url ? '' : pr.url))}
          >
            {isOpen ? '▾ ' : '▸ '}
            <Text dimColor>
              {short(pr.repo)}#{pr.number}
            </Text>{' '}
            <Text bold>{pr.title}</Text>
          </Button>
          {statusLine(pr)}
          {isOpen && details(pr)}
        </Box>
      )
    }

    const section = (group: Group, title: string) => {
      const items = visible.filter(pr => pr.authorKind === group)
      const isCollapsed = collapsed.includes(group)
      return (
        <Box flexDirection="column" rowGap={1}>
          <Button
            key={`group:${group}`}
            plain
            onPress={() =>
              void update($, collapsedAtom, list =>
                list.includes(group) ? list.filter(g => g !== group) : [...list, group],
              )
            }
          >
            {isCollapsed ? '▸ ' : '▾ '}
            <Text bold>{title}</Text> <Text dimColor>({items.length})</Text>
          </Button>
          {!isCollapsed && items.length === 0 && (
            <Text dimColor>{'  '}{tokens.length > 0 ? 'none match the filter' : 'none'}</Text>
          )}
          {!isCollapsed && items.map(row)}
        </Box>
      )
    }

    const hiddenList = () => {
      const entries = Object.entries(hidden)
      return (
        <Box flexDirection="column" rowGap={1}>
          <Text bold>Hidden ({entries.length})</Text>
          {entries.length === 0 && <Text dimColor>Nothing hidden.</Text>}
          {entries.map(([url, snoozed]) => {
            const pr = prs.find(p => p.url === url)
            return (
              <Box flexDirection="column">
                <Text>
                  <Text dimColor>{pr ? `${short(pr.repo)}#${pr.number} ` : ''}</Text>
                  {snoozed.title}
                </Text>
                <Box flexDirection="row" columnGap={1} paddingLeft={2}>
                  <Text dimColor>{describeHidden(snoozed, now)}</Text>
                  <Button key={`unhide:${url}`} dimColor onPress={() => void unhide($, url)}>
                    Unhide
                  </Button>
                </Box>
              </Box>
            )
          })}
        </Box>
      )
    }

    return (
      <Box flexDirection="column" rowGap={1}>
        <Box flexDirection="row" flexWrap="wrap" columnGap={1}>
          <Text dimColor>{status}</Text>
          <Button key="refresh" onPress={() => void refresh($, options)}>
            Refresh
          </Button>
          {(hiddenCount > 0 || showHidden) && (
            <Button key="toggle-hidden" onPress={() => void update($, showHiddenAtom, v => !v)}>
              {showHidden ? 'Back to list' : `Hidden (${hiddenCount})`}
            </Button>
          )}
        </Box>
        {meta.error !== undefined && (
          <Text color="error" wrap="wrap">
            {meta.error}
          </Text>
        )}
        {notice !== '' && <Text color="warning">{notice}</Text>}
        {showHidden ? (
          hiddenList()
        ) : (
          <Box flexDirection="column" rowGap={1}>
            <Box flexDirection="row" columnGap={1}>
              <Input
                key="filter"
                label="Filter"
                placeholder="text, repo:, label:, author:, ci:fail, is:draft, -label:…"
                value={filter}
                onInput={v => void update($, filterAtom, () => v)}
                onSubmit={v => void update($, filterAtom, () => v)}
              />
              {filter !== '' && (
                <Button key="clear-filter" dimColor onPress={() => void update($, filterAtom, () => '')}>
                  Clear
                </Button>
              )}
            </Box>
            {prs.length === 0 && !meta.isLoading && meta.error === undefined && (
              <Text dimColor>No open pull requests.</Text>
            )}
            {GROUPS.map(g => section(g.id, g.title))}
          </Box>
        )}
      </Box>
    )
  })
}

