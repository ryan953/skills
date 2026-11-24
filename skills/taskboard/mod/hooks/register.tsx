import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

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

// Bump the shape when Board's fields change, so a reload declines the old stored value.
const board = atom({ plugin: 'taskboard', key: 'board' } as const, null, { shape: 'board-5' })
const workers = atom({ plugin: 'taskboard', key: 'workers' } as const, [], { shape: 'workers-1' })
// Task ids whose tree is open in the pane.
const expanded = atom({ plugin: 'taskboard', key: 'expanded' } as const, [] as string[])
const overview = atom({ plugin: 'taskboard', key: 'overview' } as const, null, { shape: 'overview-1' })
const overviewState = atom({ plugin: 'taskboard', key: 'overviewState' } as const, { id: null, isLoading: false, error: null })
const sync = atom({ plugin: 'taskboard', key: 'sync' } as const, {
  isSyncing: false,
  error: null,
  at: null,
})

// The skill is installed at a fixed place; a login shell finds the right node on PATH.
async function cli<T = Board>($: EngineInterface, args: string[]): Promise<T> {
  const env = await $.process.hookEnv()
  const { exitCode, stdout, stderr } = await $.process.run(
    ['/bin/zsh', '-lc', 'exec node "$HOME/.claude/skills/taskboard/scripts/taskboard.mjs" "$@"', 'taskboard', ...args],
    { env, timeoutMs: 180_000 },
  )
  if (exitCode !== 0) throw new Error(stderr.trim().split('\n').pop() || `exit ${exitCode}`)
  return JSON.parse(stdout) as T
}

const pct = (p: Progress | null) => (p ? `${p.done} of ${p.total} done` : '')

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

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await $.command.register({ name: 'board', description: 'Open the taskboard pane' })
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
    return started
  })

  on('command.run', { command: 'board' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Taskboard' })
    return { text: 'Taskboard pane opened.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const b = await read($, board)
    if (e.props.hasSurvey || !b) return next(e)
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
    const now = await $.clock.now()
    const { Box, Button, Link, Text } = $.ui.resolve(e)

    const dispatchTo = (id: string) => void $.command.run({ command: 'taskboard', args: `dispatch ${id}` })
    const subRow = (t: BoardTask, c: TreeNode) => (
      <Box key={`sub:${t.id}:${c.id}`} gap={1}>
        <Text dimColor>  ▸</Text>
        <Link href={c.url} label={c.id} />
        <Text>{c.title}</Text>
        <Text dimColor>
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
        <Box key={`tree:${t.id}`} flexDirection="column">
          <Box gap={1}>
            <Text dimColor>{summary.join(' · ')}</Text>
            <Button
              key={`tree-toggle:${t.id}`}
              label={isOpen ? 'Hide tree' : 'Tree'}
              onPress={() => update($, expanded, ids => (ids.includes(t.id) ? ids.filter(i => i !== t.id) : [...ids, t.id]))}
            />
          </Box>
          {isOpen && tr.parent && (
            <Box gap={1}>
              <Text dimColor>parent</Text>
              {tr.parent.url ? <Link href={tr.parent.url} label={tr.parent.id} /> : <Text>{tr.parent.id}</Text>}
              <Text>{tr.parent.title ?? ''}</Text>
            </Box>
          )}
          {isOpen && tr.children.length > 0 && <Text dimColor>open sub-issues ({tr.children.length})</Text>}
          {isOpen && tr.children.map(c => subRow(t, c))}
          {isOpen && tr.siblings.length > 0 && <Text dimColor>open siblings</Text>}
          {isOpen && tr.siblings.map(c => subRow(t, c))}
          {isOpen && tr.moreSiblings > 0 && <Text dimColor>  and {tr.moreSiblings} more</Text>}
        </Box>
      )
    }
    if (!b) return <Text dimColor>{s.error ? `No ledger: ${s.error}` : 'Loading the ledger…'}</Text>

    const row = (t: BoardTask) => (
      <Box key={`row:${t.id}`} flexDirection="column">
        <Box gap={1}>
          <Text bold>{t.id}</Text>
          <Text>{t.title}</Text>
          {ws
            .filter(w => w.task === t.id)
            .slice(0, 1)
            .map(w => (
              <Text color="success">
                {VERB[t.stage] ?? 'Implementing'} · {ago(w.turnStartedAt, now)}
              </Text>
            ))}
        </Box>
        {t.actions
          .filter(a => a.type === 'follow-up')
          .map(a => (
            <Text color="warning">Left to do: {a.reason}</Text>
          ))}
        {t.prs
          .filter(p => p.detail)
          .map(p => (
            <Box key={`pr:${p.key}`} gap={1}>
              <Link href={p.url} label={p.label} />
              {p.headAt && now - Date.parse(p.headAt) < 60 * 60_000 && <Text color="success">pushed {ago(p.headAt, now)} ago</Text>}
              <Text dimColor>{p.detail}</Text>
            </Box>
          ))}
        {tree(t)}
        <Box gap={1}>
          <Text dimColor>{t.parts}</Text>
          {t.url && <Link href={t.url} label="Open" />}
          <Button key={`overview:${t.id}`} label="Overview" onPress={() => void openOverview($, t.id)} />
          {!NO_DISPATCH.has(t.stage) && (
            <Button
              key={`dispatch:${t.id}`}
              label="Dispatch"
              onPress={() => dispatchTo(t.id)}
            />
          )}
        </Box>
      </Box>
    )

    const cleanup = b.counts.archive + b.counts.close + b.counts.check
    return (
      <Box flexDirection="column" gap={1}>
        <Box gap={1}>
          <Text dimColor>
            {b.counts.open} open · {b.counts.queue} in review queue · {b.counts.backlog} filed, unlinked · synced{' '}
            {b.generatedAt.slice(11, 16)} UTC
          </Text>
          <Button key="pane-sync" label={s.isSyncing ? 'Syncing…' : 'Sync'} onPress={() => void runSync($)} />
          {cleanup > 0 && (
            <Button
              key="pane-cleanup"
              label={`Clean up (${cleanup})`}
              onPress={() => void $.command.run({ command: 'taskboard', args: 'ask the sessions to check, then offer the archive and close actions' })}
            />
          )}
        </Box>
        {s.error && <Text color="error">Last sync failed: {s.error}</Text>}
        {STAGES.map(stage => {
          const ts = b.tasks.filter(t => t.stage === stage)
          if (!ts.length) return null
          return (
            <Box key={`stage:${stage}`} flexDirection="column">
              <Text bold underline>
                {stage} ({ts.length})
              </Text>
              {ts.map(row)}
            </Box>
          )
        })}
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
        <Text dimColor={n.isDone} bold={n.id === o.tree?.self}>
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
          <Text bold>{o.id}</Text>
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
          <Text bold>Items</Text>
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
            <Text bold>Description</Text>
            <Markdown key="ov-description" text={clip(t.description, DESCRIPTION_LIMIT)} />
          </Box>
        )}
        {o.comments.length > 0 && (
          <Box flexDirection="column">
            <Text bold>Latest comments</Text>
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
                <Text bold>Parent</Text>
                <Link href={o.tree.parent.url} label={o.tree.parent.id} />
                <Text>{o.tree.parent.title}</Text>
                <Text dimColor>{pct(o.tree.parent.progress)}</Text>
              </Box>
            )}
            {o.tree.children.length > 0 && <Text bold>Sub-issues · {pct(o.tree.progress)}</Text>}
            {o.tree.children.map(node)}
            {o.tree.siblings.length > 0 && <Text bold>Siblings ({o.tree.siblings.length})</Text>}
            {o.tree.siblings.map(node)}
          </Box>
        )}
      </Box>
    )
  })
}
