import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Board, BoardTask } from '../types'

const PANE = 'taskboard'
const SYNC_EVERY_MS = 10 * 60 * 1000
const STAGES = ['needs-you', 'follow-up', 'merge', 'iterate', 'review', 'fix', 'validate', 'verify', 'adhoc']
// Stages where the next move is the user's; dispatch would only answer "ask the user".
const NO_DISPATCH = new Set(['needs-you', 'merge'])

// Bump the shape when Board's fields change, so a reload declines the old stored value.
const board = atom({ plugin: 'taskboard', key: 'board' } as const, null, { shape: 'board-2' })
const sync = atom({ plugin: 'taskboard', key: 'sync' } as const, {
  isSyncing: false,
  error: null,
  at: null,
})

// The skill is installed at a fixed place; a login shell finds the right node on PATH.
async function cli($: EngineInterface, args: string[]) {
  const env = await $.process.hookEnv()
  const { exitCode, stdout, stderr } = await $.process.run(
    ['/bin/zsh', '-lc', 'exec node "$HOME/.claude/skills/taskboard/scripts/taskboard.mjs" "$@"', 'taskboard', ...args],
    { env, timeoutMs: 180_000 },
  )
  if (exitCode !== 0) throw new Error(stderr.trim().split('\n').pop() || `exit ${exitCode}`)
  return JSON.parse(stdout) as Board
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

// session.start can run more than once in one environment, so keep one timer at a time.
let timer: { cancel: () => void } | null = null

async function runSync($: EngineInterface, offline = false) {
  const state = await read($, sync)
  if (state.isSyncing) return
  await update($, sync, s => ({ ...s, isSyncing: true, error: null }))
  try {
    const before = await read($, board)
    const after = await cli($, offline ? ['show', '--board'] : ['sync', '--board'])
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
    await runSync($, true)
    timer?.cancel()
    // Linear, GitHub and session files only: jr needs MCP tools, so its snapshot is as of the last /taskboard sync.
    timer = $.clock.every(SYNC_EVERY_MS, () => void runSync($))
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
    const { Box, Button, Text } = $.ui.resolve(e)
    const by = (stage: string) => b.tasks.filter(t => t.stage === stage).length
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
        <Text dimColor>{s.isSyncing ? 'syncing…' : s.error ? `sync failed: ${s.error}` : ''}</Text>
        <Button key="board-open" label="Board" onPress={() => void $.ui.open({ id: PANE, title: 'Taskboard' })} />
        <Button key="board-sync" label="Sync" onPress={() => void runSync($)} />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const b = await read($, board)
    const s = await read($, sync)
    const { Box, Button, Link, Text } = $.ui.resolve(e)
    if (!b) return <Text dimColor>{s.error ? `No ledger: ${s.error}` : 'Loading the ledger…'}</Text>

    const row = (t: BoardTask) => (
      <Box key={`row:${t.id}`} flexDirection="column">
        <Box gap={1}>
          <Text bold>{t.id}</Text>
          <Text>{t.title}</Text>
        </Box>
        {t.actions
          .filter(a => a.type === 'follow-up')
          .map(a => (
            <Text color="warning">Left to do: {a.reason}</Text>
          ))}
        <Box gap={1}>
          <Text dimColor>{t.parts}</Text>
          {t.url && <Link href={t.url} label="Open" />}
          {!NO_DISPATCH.has(t.stage) && (
            <Button
              key={`dispatch:${t.id}`}
              label="Dispatch"
              onPress={() => void $.command.run({ command: 'taskboard', args: `dispatch ${t.id}` })}
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
}
