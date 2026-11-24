import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, ThemeSetArgs } from 'claude-code'

import type { Board, BoardTask, Overview, OverviewNode, Progress, TreeNode, Worker } from '../types'

const PANE = 'taskboard'
const OVERVIEW = 'taskboard-overview'
// Long Linear text is cut so one task cannot fill the pane; the ticket link has the rest.
const DESCRIPTION_LIMIT = 6000
const COMMENT_LIMIT = 1500
const SYNC_EVERY_MS = 10 * 60 * 1000
// Worker state is local files only, so it can refresh far more often than the full sync.
const WORKERS_EVERY_MS = 60 * 1000
const STAGES = ['needs-you', 'follow-up', 'merge', 'iterate', 'review', 'fix', 'validate', 'verify', 'adhoc']
// Stages where the next move is the user's; dispatch would only answer "ask the user".
const NO_DISPATCH = new Set(['needs-you', 'merge'])
const STAGE_LABEL: Record<string, string> = {
  'needs-you': 'Needs you',
  'follow-up': 'Follow-up',
  merge: 'Ready to merge',
  iterate: 'Iterate',
  review: 'Review',
  fix: 'Fix',
  validate: 'Validate',
  verify: 'Verify',
  adhoc: 'Ad hoc',
}
// Only the stages that ask for the user get a colored border; the rest stay quiet.
const STAGE_COLOR: Record<string, string | undefined> = { 'needs-you': 'warning', 'follow-up': 'warning', merge: 'success' }
// Percent widths leave room for the column gap.
const CARD_WIDTH: Record<number, string> = { 1: '100%', 2: '48%', 3: '31%' }
// Each level under a heading starts this many cells further in, so team > project > card reads as a tree.
const INDENT = 2

// Bump the shape when Board's fields change, so a reload declines the old stored value.
const board = atom({ plugin: 'taskboard', key: 'board' } as const, null, { shape: 'board-6' })
const workers = atom({ plugin: 'taskboard', key: 'workers' } as const, [], { shape: 'workers-1' })
// Task ids whose tree is open in the pane.
const expanded = atom({ plugin: 'taskboard', key: 'expanded' } as const, [] as string[])
// Section and project keys folded in the pane. Every section starts open, so a new team or repo is never hidden.
const folded = atom({ plugin: 'taskboard', key: 'folded' } as const, [] as string[])
const overview = atom({ plugin: 'taskboard', key: 'overview' } as const, null, { shape: 'overview-1' })
const overviewState = atom({ plugin: 'taskboard', key: 'overviewState' } as const, { id: null, isLoading: false, error: null })
const sync = atom({ plugin: 'taskboard', key: 'sync' } as const, {
  isSyncing: false,
  error: null,
  at: null,
})
// Every session loads the mod, but only the management sessions run it.
const enabled = atom({ plugin: 'taskboard', key: 'enabled' } as const, false)
// $.store is shared by every session, so the list of enabled sessions outlives a restart.
const ENABLED_SESSIONS = 'enabledSessions'
const OFF_TEXT = 'The taskboard is off in this session. Type /board on in the session that manages the others.'

// The backdrop tells the management session apart from the sessions it dispatches to at a glance.
// Palette names, not raw colors, so each ground follows light and dark mode.
const MANAGER_LOOK: ThemeSetArgs = {
  backdrop: { gradient: { shape: 'radial', stops: [{ at: 0, color: 'bg-pro' }, { at: 0.7, color: 'surface-0' }] } },
}
const WORKER_LOOK: ThemeSetArgs = {
  backdrop: { gradient: { angle: 180, stops: [{ at: 0.6, color: 'surface-0' }, { at: 1, color: 'bg-accent' }] } },
}

async function applyLook($: EngineInterface, isManager: boolean) {
  try {
    await $.theme.set(isManager ? MANAGER_LOOK : WORKER_LOOK)
  } catch (err) {
    // A build or surface that refuses the look still gets a working board.
    $.ui.log(`taskboard: backdrop not set: ${String((err as Error).message ?? err)}`)
  }
}

// The skill is installed at a fixed place; a login shell finds the right node on PATH.
async function run($: EngineInterface, args: string[]): Promise<string> {
  const env = await $.process.hookEnv()
  const { exitCode, stdout, stderr } = await $.process.run(
    ['/bin/zsh', '-lc', 'exec node "$HOME/.claude/skills/taskboard/scripts/taskboard.mjs" "$@"', 'taskboard', ...args],
    { env, timeoutMs: 180_000 },
  )
  if (exitCode !== 0) throw new Error(stderr.trim().split('\n').pop() || `exit ${exitCode}`)
  return stdout
}

async function cli<T = Board>($: EngineInterface, args: string[]): Promise<T> {
  return JSON.parse(await run($, args)) as T
}

async function enabledSessions($: EngineInterface): Promise<string[]> {
  const v = await $.store.get(ENABLED_SESSIONS)
  return Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string') : []
}

const pct = (p: Progress | null) => (p ? `${p.done} of ${p.total} done` : '')

type Section = { key: string; title: string; projects: { key: string; title: string | null; tasks: BoardTask[] }[] }

const NO_PROJECT = 'No project'
const byName = (a: string, b: string) => a.localeCompare(b)

// Teams first, then repos for PRs with no ticket, then the rest. Names sort alphabetically so a
// section stays put between syncs; each card carries its stage instead, sorted by urgency inside a group.
function sections(tasks: BoardTask[]): Section[] {
  const stageRank = (t: BoardTask) => STAGES.indexOf(t.stage)
  const sorted = [...tasks].sort((a, b) => stageRank(a) - stageRank(b))
  const teams = new Map<string, Map<string, BoardTask[]>>()
  const repos = new Map<string, BoardTask[]>()
  const other: BoardTask[] = []
  for (const t of sorted) {
    const g = t.group
    if (g.kind === 'team') {
      const projects = teams.get(g.team) ?? new Map<string, BoardTask[]>()
      teams.set(g.team, projects)
      const name = g.project ?? NO_PROJECT
      projects.set(name, [...(projects.get(name) ?? []), t])
    } else if (g.kind === 'repo') repos.set(g.repo, [...(repos.get(g.repo) ?? []), t])
    else other.push(t)
  }
  const projectOrder = (a: string, b: string) => (a === NO_PROJECT ? 1 : b === NO_PROJECT ? -1 : byName(a, b))
  return [
    ...[...teams.keys()].sort(byName).map(team => {
      const projects = teams.get(team)!
      const names = [...projects.keys()].sort(projectOrder)
      // A team whose tickets have no project needs no project heading.
      const solo = names.length === 1 && names[0] === NO_PROJECT
      return {
        key: `team:${team}`,
        title: team,
        projects: names.map(name => ({ key: `team:${team}:${name}`, title: solo ? null : name, tasks: projects.get(name)! })),
      }
    }),
    ...[...repos.keys()].sort(byName).map(repo => ({ key: `repo:${repo}`, title: repo, projects: [{ key: `repo:${repo}`, title: null, tasks: repos.get(repo)! }] })),
    ...(other.length ? [{ key: 'other', title: 'Other', projects: [{ key: 'other', title: null, tasks: other }] }] : []),
  ]
}

const VERB: Record<string, string> = { validate: 'Validating', review: 'Reviewing', verify: 'Verifying' }

function ago(iso: string, now: number) {
  const m = Math.max(0, Math.round((now - Date.parse(iso)) / 60_000))
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`
}

async function readWorkers($: EngineInterface) {
  try {
    const list = await cli<Worker[]>($, ['workers'])
    await update($, workers, () => list)
  } catch {
    // The next tick tries again; a stale list is better than none.
  }
}

// What changed in a way that asks for the user: a task that newly needs them or can merge,
// or new clean-up to approve.
function alerts(before: Board | null, after: Board): string[] {
  if (!before) return []
  const was = new Map(before.tasks.map(t => [t.id, t.stage]))
  const out: string[] = []
  for (const t of after.tasks) {
    if ((t.stage === 'needs-you' || t.stage === 'merge') && was.get(t.id) !== t.stage) {
      out.push(`${t.id} ${t.stage === 'merge' ? 'can merge' : 'needs you'}`)
    }
  }
  if (after.counts.followUp > before.counts.followUp) out.push(`${after.counts.followUp - before.counts.followUp} new follow-ups`)
  const cleanup = (c: Board['counts']) => c.archive + c.close + c.check
  if (cleanup(after.counts) > cleanup(before.counts)) out.push(`${cleanup(after.counts) - cleanup(before.counts)} new clean-up actions`)
  return out
}

const clip = (text: string, n: number) => (text.length > n ? `${text.slice(0, n)}…` : text)

// The Overview is fetched when it opens, so the 10-minute sync stays cheap.
async function openOverview($: EngineInterface, id: string) {
  await update($, overviewState, () => ({ id, isLoading: true, error: null }))
  void $.ui.open({ id: OVERVIEW, title: 'Task overview' })
  try {
    const data = await cli<Overview>($, ['detail', id])
    // A later press may have picked another task while this one loaded.
    if ((await read($, overviewState)).id !== id) return
    await update($, overview, () => data)
    await update($, overviewState, s => ({ ...s, isLoading: false }))
  } catch (err) {
    await update($, overviewState, s => ({ ...s, isLoading: false, error: String((err as Error).message ?? err) }))
  }
}

// session.start can run more than once in one environment, so keep one timer at a time.
let timer: { cancel: () => void } | null = null
let workerTimer: { cancel: () => void } | null = null

// 'saved' reads the ledger, 'timer' fetches only when no other session's timer did so lately,
// 'fetch' always fetches (the Sync button).
async function runSync($: EngineInterface, mode: 'saved' | 'timer' | 'fetch' = 'fetch') {
  const state = await read($, sync)
  if (state.isSyncing) return
  await update($, sync, s => ({ ...s, isSyncing: true, error: null }))
  try {
    const before = await read($, board)
    const args = { saved: ['show', '--board'], timer: ['sync', '--board', '--max-age', String(SYNC_EVERY_MS / 1000 - 60)], fetch: ['sync', '--board'] }[mode]
    const after = await cli($, args)
    await update($, board, () => after)
    await update($, sync, () => ({ isSyncing: false, error: null, at: Date.now() }))
    const news = alerts(before, after)
    if (news.length) {
      $.ui.toast(`taskboard: ${news.join(', ')}`, { timeoutMs: 8000 })
      void $.prompt.suggest({ text: '/taskboard show what changed and what needs me' })
    }
  } catch (err) {
    await update($, sync, s => ({ ...s, isSyncing: false, error: String((err as Error).message ?? err) }))
  }
}

async function start($: EngineInterface) {
  await update($, enabled, () => true)
  await applyLook($, true)
  // $.state outlives a reload, so a sync cut off by one would otherwise block every later sync.
  await update($, sync, s => ({ ...s, isSyncing: false }))
  // Draw the last saved ledger at once (a local read); the first fetch waits for the timer or Sync.
  await runSync($, 'saved')
  timer?.cancel()
  // Linear, GitHub and session files only: jr needs MCP tools, so its snapshot is as of the last /taskboard sync.
  timer = $.clock.every(SYNC_EVERY_MS, () => void runSync($, 'timer'))
  await readWorkers($)
  workerTimer?.cancel()
  workerTimer = $.clock.every(WORKERS_EVERY_MS, () => void readWorkers($))
}

async function stop($: EngineInterface) {
  timer?.cancel()
  workerTimer?.cancel()
  timer = workerTimer = null
  await update($, enabled, () => false)
  await applyLook($, false)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({ name: 'board', description: 'Open the taskboard pane; /board on|off runs it in this session' })
    if ((await enabledSessions($)).includes(await $.session.id())) await start($)
    else await stop($)
    return started
  })

  on('command.run', { command: 'board' }, async ($, e) => {
    const arg = e.args.trim()
    const id = await $.session.id()
    const ids = await enabledSessions($)
    if (arg === 'on') {
      await $.store.set(ENABLED_SESSIONS, [...new Set([...ids, id])])
      // A manager session is left out of the ledger, so the board never lists itself.
      const note = await run($, ['manager', 'add', id]).then(
        () => '',
        err => ` It could not be marked as a manager: ${(err as Error).message}`,
      )
      await start($)
      await $.ui.open({ id: PANE, title: 'Taskboard' })
      return { text: `The taskboard is on in this session.${note}` }
    }
    if (arg === 'off') {
      await $.store.set(ENABLED_SESSIONS, ids.filter(s => s !== id))
      await run($, ['manager', 'remove', id]).catch(() => {})
      await stop($)
      return { text: 'The taskboard is off in this session.' }
    }
    if (arg) return { text: 'Usage: /board, /board on, or /board off' }
    if (!(await read($, enabled))) return { text: OFF_TEXT }
    await $.ui.open({ id: PANE, title: 'Taskboard' })
    return { text: 'Taskboard pane opened.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const b = await read($, board)
    if (e.props.hasSurvey || !b || !(await read($, enabled))) return next(e)
    const s = await read($, sync)
    const ws = await read($, workers)
    const now = await $.clock.now()
    const { Box, Button, Text } = $.ui.resolve(e)
    const by = (stage: string) => b.tasks.filter(t => t.stage === stage).length
    const oldest = ws.map(w => w.turnStartedAt).sort()[0]
    const parts = [
      b.counts.needsYou && `${b.counts.needsYou} need you`,
      b.counts.followUp && `${b.counts.followUp} follow-ups`,
      by('merge') && `${by('merge')} to merge`,
      by('iterate') && `${by('iterate')} iterate`,
      by('review') && `${by('review')} review`,
      b.counts.check && `${b.counts.check} to check`,
      b.counts.archive && `${b.counts.archive} to archive`,
      b.counts.close && `${b.counts.close} to close`,
    ].filter(Boolean)
    return (
      <Box gap={1}>
        <Text color={b.counts.needsYou ? 'warning' : undefined}>taskboard: {parts.join(' · ') || 'nothing waiting'}</Text>
        {oldest && (
          <Text color="success">
            {ws.length} {ws.length === 1 ? 'worker' : 'workers'} running · {ago(oldest, now)}
          </Text>
        )}
        <Text dimColor>{s.isSyncing ? 'syncing…' : s.error ? `sync failed: ${s.error}` : ''}</Text>
        <Button key="board-open" label="Board" onPress={() => void $.ui.open({ id: PANE, title: 'Taskboard' })} />
        <Button key="board-sync" label="Sync" onPress={() => void runSync($)} />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const b = await read($, board)
    const s = await read($, sync)
    const ws = await read($, workers)
    const open = new Set(await read($, expanded))
    const shut = new Set(await read($, folded))
    const now = await $.clock.now()
    const { Box, Button, Link, Text } = $.ui.resolve(e)

    if (!(await read($, enabled))) return <Text dimColor>{OFF_TEXT}</Text>
    if (!b) return <Text dimColor>{s.error ? `No ledger: ${s.error}` : 'Loading the ledger…'}</Text>

    // Cards wrap into as many columns as the pane is wide enough for.
    const cols = e.props.bodyColumns >= 150 ? 3 : e.props.bodyColumns >= 96 ? 2 : 1
    const cardWidth = CARD_WIDTH[cols]
    const dispatchTo = (id: string) => void $.command.run({ command: 'taskboard', args: `dispatch ${id}` })

    const subRow = (t: BoardTask, c: TreeNode) => (
      <Box key={`sub:${t.id}:${c.id}`} gap={1} flexWrap="wrap" alignItems="center">
        <Text dimColor>▸</Text>
        <Link href={c.url} label={c.id} />
        <Text wrap="truncate-end">{c.title}</Text>
        <Text dimColor size="caption">
          {c.state}
          {c.prs.length ? ` · ${c.prs.join(', ')}` : ''}
        </Text>
        {c.canDispatch && <Button key={`dispatch-sub:${t.id}:${c.id}`} label="Dispatch" onPress={() => dispatchTo(c.task ?? c.id)} />}
      </Box>
    )
    const tree = (t: BoardTask) => {
      const tr = t.tree
      if (!tr) return null
      const summary = [
        tr.parent && `↑ ${tr.parent.id}${tr.parent.progress ? ` · ${pct(tr.parent.progress)}` : ''}`,
        tr.progress && `sub-issues ${pct(tr.progress)}`,
      ].filter(Boolean)
      const isOpen = open.has(t.id)
      return (
        <Box key={`tree:${t.id}`} flexDirection="column" gap={0}>
          <Box gap={1} alignItems="center" justifyContent="space-between">
            <Text dimColor size="caption">{summary.join(' · ')}</Text>
            <Button
              key={`tree-toggle:${t.id}`}
              label={isOpen ? 'Hide tree' : 'Tree'}
              onPress={() => update($, expanded, ids => (ids.includes(t.id) ? ids.filter(i => i !== t.id) : [...ids, t.id]))}
            />
          </Box>
          {isOpen && (
            <Box flexDirection="column" paddingLeft={1}>
              {tr.parent && (
                <Box gap={1}>
                  <Text dimColor size="caption">parent</Text>
                  {tr.parent.url ? <Link href={tr.parent.url} label={tr.parent.id} /> : <Text>{tr.parent.id}</Text>}
                  <Text wrap="truncate-end">{tr.parent.title ?? ''}</Text>
                </Box>
              )}
              {tr.children.length > 0 && <Text dimColor size="caption">open sub-issues ({tr.children.length})</Text>}
              {tr.children.map(c => subRow(t, c))}
              {tr.siblings.length > 0 && <Text dimColor size="caption">open siblings</Text>}
              {tr.siblings.map(c => subRow(t, c))}
              {tr.moreSiblings > 0 && <Text dimColor size="caption">and {tr.moreSiblings} more</Text>}
            </Box>
          )}
        </Box>
      )
    }

    const card = (t: BoardTask) => {
      const w = ws.find(x => x.task === t.id)
      const accent = STAGE_COLOR[t.stage]
      return (
        <Box
          key={`row:${t.id}`}
          flexDirection="column"
          width={cardWidth}
          borderStyle="round"
          borderColor={accent}
          borderDimColor={!accent}
          paddingX={1}
          rowGap={1}
        >
          <Box flexDirection="column">
            <Box gap={1} justifyContent="space-between">
              <Box gap={1} alignItems="center">
                <Text weight="semibold" tabular>{t.id}</Text>
                <Text size="caption" color={accent} dimColor={!accent}>{STAGE_LABEL[t.stage] ?? t.stage}</Text>
              </Box>
              {w && (
                <Text color="success" size="caption">
                  {VERB[t.stage] ?? 'Implementing'} · {ago(w.turnStartedAt, now)}
                </Text>
              )}
            </Box>
            <Text maxLines={2}>{t.title}</Text>
          </Box>
          {t.actions
            .filter(a => a.type === 'follow-up')
            .map(a => (
              <Text key={`follow:${t.id}:${a.item}`} color="warning">Left to do: {a.reason}</Text>
            ))}
          {t.prs.some(p => p.detail) && (
            <Box flexDirection="column">
              {t.prs
                .filter(p => p.detail)
                .map(p => (
                  <Box key={`pr:${p.key}`} flexDirection="column">
                    <Box gap={1}>
                      <Link href={p.url} label={p.label} />
                      {p.headAt && now - Date.parse(p.headAt) < 60 * 60_000 && <Text color="success" size="caption">pushed {ago(p.headAt, now)} ago</Text>}
                    </Box>
                    <Text dimColor size="caption">{p.detail}</Text>
                  </Box>
                ))}
            </Box>
          )}
          {tree(t)}
          <Box flexDirection="column">
            <Text dimColor size="caption" wrap="truncate-end">{t.parts}</Text>
            <Box gap={1} justifyContent="flex-end">
              {t.url && <Link href={t.url} label="Open" />}
              <Button key={`overview:${t.id}`} label="Overview" onPress={() => void openOverview($, t.id)} />
              {!NO_DISPATCH.has(t.stage) && <Button key={`dispatch:${t.id}`} label="Dispatch" variant="primary" onPress={() => dispatchTo(t.id)} />}
            </Box>
          </Box>
        </Box>
      )
    }

    const cleanup = b.counts.archive + b.counts.close + b.counts.check
    // A desktop draws every Button as a native button, so only the marker is one and the title
    // stays plain text. The label names the marker by the title, so it reads the same folded or not.
    const heading = (key: string, title: string, count: number, size: 'heading' | 'body') => {
      const isShut = shut.has(key)
      return (
        <Box gap={1} alignItems="center">
          <Button
            key={`fold:${key}`}
            plain
            dimColor
            label={title}
            onPress={() => update($, folded, keys => (keys.includes(key) ? keys.filter(k => k !== key) : [...keys, key]))}
          >
            {isShut ? '▸' : '▾'}
          </Button>
          <Text size={size} weight="semibold">{title}</Text>
          <Text dimColor size="caption" tabular>{count}</Text>
        </Box>
      )
    }

    return (
      <Box flexDirection="column" gap={2} paddingX={1} paddingY={1}>
        <Box flexDirection="column" gap={1}>
          <Box justifyContent="space-between" alignItems="center" flexWrap="wrap" gap={1}>
            <Text size="heading" weight="semibold">Taskboard</Text>
            <Box gap={1} alignItems="center">
              <Text dimColor size="caption">synced {b.generatedAt.slice(11, 16)} UTC</Text>
              {cleanup > 0 && (
                <Button
                  key="pane-cleanup"
                  label={`Clean up (${cleanup})`}
                  onPress={() => void $.command.run({ command: 'taskboard', args: 'ask the sessions to check, then offer the archive and close actions' })}
                />
              )}
              <Button key="pane-sync" label={s.isSyncing ? 'Syncing…' : 'Sync'} onPress={() => void runSync($)} />
            </Box>
          </Box>
          <Text dimColor size="caption">
            {b.counts.open} open · {b.counts.queue} in review queue · {b.counts.backlog} filed, unlinked
          </Text>
          {s.error && <Text color="error">Last sync failed: {s.error}</Text>}
        </Box>
        {sections(b.tasks).map(sec => (
          <Box key={sec.key} flexDirection="column" gap={1}>
            {heading(sec.key, sec.title, sec.projects.reduce((n, p) => n + p.tasks.length, 0), 'heading')}
            {!shut.has(sec.key) && (
              <Box flexDirection="column" gap={1} paddingLeft={INDENT}>
                {sec.projects.map(p => (
                  <Box key={p.key} flexDirection="column" gap={1}>
                    {p.title && heading(p.key, p.title, p.tasks.length, 'body')}
                    {!(p.title && shut.has(p.key)) && (
                      <Box flexWrap="wrap" columnGap={2} rowGap={1} paddingLeft={p.title ? INDENT : 0}>
                        {p.tasks.map(card)}
                      </Box>
                    )}
                  </Box>
                ))}
              </Box>
            )}
          </Box>
        ))}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: OVERVIEW }, async ($, e) => {
    const o = await read($, overview)
    const st = await read($, overviewState)
    const { Box, Button, Link, Markdown, Text } = $.ui.resolve(e)
    if (st.error) return <Text color="error">Could not load {st.id}: {st.error}</Text>
    if (!o || o.id !== st.id) return <Text dimColor>{st.id ? `Loading ${st.id}…` : 'Press Overview on a task in the board.'}</Text>

    const dispatchTo = (id: string) => void $.command.run({ command: 'taskboard', args: `dispatch ${id}` })
    const t = o.ticket
    const prop = (name: string, value: string | null | undefined) =>
      value ? (
        <Box key={`prop:${name}`} gap={1}>
          <Text dimColor>{name}</Text>
          <Text>{value}</Text>
        </Box>
      ) : null
    const node = (n: OverviewNode) => (
      <Box key={`ov:${n.id}`} gap={1}>
        <Link href={n.url} label={n.id} />
        <Text dimColor={n.isDone} weight={n.id === o.tree?.self ? 'semibold' : undefined}>
          {n.title}
        </Text>
        <Text dimColor>
          {n.state}
          {n.prs.length ? ` · ${n.prs.join(', ')}` : ''}
        </Text>
        {n.canDispatch && <Button key={`ov-dispatch:${n.id}`} label="Dispatch" onPress={() => dispatchTo(n.task ?? n.id)} />}
      </Box>
    )

    return (
      <Box flexDirection="column" gap={1}>
        <Box gap={1}>
          <Text weight="semibold">{o.id}</Text>
          <Text>{o.title}</Text>
          <Text dimColor>
            {o.stage} · {o.kind}
          </Text>
          {t && <Link href={t.url} label="Open ticket" />}
          <Button key="ov-refresh" label={st.isLoading ? 'Loading…' : 'Refresh'} onPress={() => void openOverview($, o.id)} />
          {!NO_DISPATCH.has(o.stage) && <Button key="ov-dispatch-task" label="Dispatch" onPress={() => dispatchTo(o.id)} />}
        </Box>
        {t && (
          <Box flexDirection="column">
            {prop('Status', t.status)}
            {prop('Priority', t.priority)}
            {prop('Assignee', t.assignee ?? 'unassigned')}
            {prop('Labels', t.labels.join(', '))}
            {prop('Project', t.project)}
            {prop('Cycle', t.cycle)}
            {prop('Team', t.team)}
            {prop('Branch', t.branch)}
            {prop('Owner', o.owner)}
          </Box>
        )}
        {o.actions.length > 0 && (
          <Box flexDirection="column">
            {o.actions.map(a => (
              <Text color={a.type === 'follow-up' || a.type === 'needs-you' ? 'warning' : undefined}>
                {a.type}: {a.reason ?? a.item}
              </Text>
            ))}
          </Box>
        )}
        <Box flexDirection="column">
          <Text weight="semibold">Items</Text>
          {o.items.map(i => (
            <Box key={`item:${i.key}`} gap={1}>
              {i.url ? <Link href={i.url} label={i.label} /> : <Text>{i.label}</Text>}
              <Text>{i.title}</Text>
              {i.detail && <Text dimColor>{i.detail}</Text>}
            </Box>
          ))}
        </Box>
        {t?.description && (
          <Box flexDirection="column">
            <Text weight="semibold">Description</Text>
            <Markdown key="ov-description" text={clip(t.description, DESCRIPTION_LIMIT)} />
          </Box>
        )}
        {o.comments.length > 0 && (
          <Box flexDirection="column">
            <Text weight="semibold">Latest comments</Text>
            {o.comments.map((c, n) => (
              <Box key={`comment:${n}`} flexDirection="column">
                <Text dimColor>
                  {c.author} · {c.at.slice(0, 10)}
                </Text>
                <Markdown key={`comment-body:${n}`} text={clip(c.body, COMMENT_LIMIT)} />
              </Box>
            ))}
            {o.moreComments > 0 && <Text dimColor>and {o.moreComments} older</Text>}
          </Box>
        )}
        {o.tree && (
          <Box flexDirection="column">
            {o.tree.parent && (
              <Box gap={1}>
                <Text weight="semibold">Parent</Text>
                <Link href={o.tree.parent.url} label={o.tree.parent.id} />
                <Text>{o.tree.parent.title}</Text>
                <Text dimColor>{pct(o.tree.parent.progress)}</Text>
              </Box>
            )}
            {o.tree.children.length > 0 && <Text weight="semibold">Sub-issues · {pct(o.tree.progress)}</Text>}
            {o.tree.children.map(node)}
            {o.tree.siblings.length > 0 && <Text weight="semibold">Siblings ({o.tree.siblings.length})</Text>}
            {o.tree.siblings.map(node)}
          </Box>
        )}
      </Box>
    )
  })
}
