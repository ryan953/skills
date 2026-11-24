import { expect, test } from 'claude-code/testing'

const PANE = {
  plugin: 'taskboard',
  component: 'Pane',
  requestId: 'taskboard',
  props: {
    title: 'Taskboard',
    isFocused: false,
    bodyColumns: 80,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const task = (id: string, stage: string) => ({
  id,
  title: `Title ${id}`,
  stage,
  kind: 'cycle',
  owner: null,
  url: `https://linear.app/x/${id}`,
  parts: `${id} In Progress`,
  actions: stage === 'needs-you' ? [{ type: 'needs-you', item: 'jr-1', reason: 'jr needs input' }] : [],
  prs:
    stage === 'iterate'
      ? [{ key: 'getsentry/sentry#131651', label: '#131651 draft', url: 'https://github.com/getsentry/sentry/pull/131651', detail: '+12 −3 · 2 files · ✓40 ✗1 · warden: no problems' }]
      : [],
})

const BOARD = {
  generatedAt: '2026-11-23T23:09:22.202Z',
  counts: { open: 3, needsYou: 1, followUp: 1, check: 0, archive: 0, close: 0, queue: 38, backlog: 46 },
  tasks: [
    task('VDY-432', 'needs-you'),
    task('VDY-433', 'iterate'),
    { ...task('VDY-381', 'follow-up'), actions: [{ type: 'follow-up', item: 'cc-1', reason: 'file the Safari ticket' }] },
  ],
}

function engine(on: any, calls: string[][], prompts: string[], run = { fail: false }) {
  // Refusing the first period ends the interval, so no timer runs in a test.
  on('clock.every', () => ({ deny: 'no timer in tests' }))
  on('command.register', () => ({ value: { command: 'board' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_: unknown, e: any) => ({ cwd: e.cwd }))
  on('process.hookEnv', () => ({ value: {} }))
  on('process.run', (_: unknown, e: any) => {
    calls.push([...e.argv])
    return run.fail
      ? { value: { exitCode: 1, stdout: '', stderr: 'gh: not logged in' } }
      : { value: { exitCode: 0, stdout: JSON.stringify(BOARD), stderr: '' } }
  })
  on('command.run', (_: unknown, e: any) => {
    prompts.push(`/${e.command} ${e.args}`)
    return { value: {} }
  })
}

test('start draws the saved ledger without fetching, and Dispatch submits the task', async ($, on) => {
  const calls: string[][] = []
  const prompts: string[] = []
  engine(on, calls, prompts)

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(calls.length).toBe(1)
  expect(calls[0]?.slice(-2)).toEqual(['show', '--board'])

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /^needs-you/ }))?.text).toBe('needs-you (1)')
  expect((await ui.find({ type: 'Text', text: /^iterate/ }))?.text).toBe('iterate (1)')
  expect((await ui.find({ type: 'Text', text: /^Left to do/ }))?.text).toBe('Left to do: file the Safari ticket')
  expect((await ui.find({ type: 'Text', text: /warden/ }))?.text).toBe('+12 −3 · 2 files · ✓40 ✗1 · warden: no problems')

  // A task that waits for the user has no Dispatch button.
  await expect($.ui.press({ plugin: 'taskboard', key: 'dispatch:VDY-432' })).rejects.toBeTruthy()
  await $.ui.press({ plugin: 'taskboard', key: 'dispatch:VDY-433' })
  expect(prompts).toEqual(['/taskboard dispatch VDY-433'])
  await ui.unmount()
})

test('Sync fetches, and a failed sync shows its error', async ($, on) => {
  const calls: string[][] = []
  const run = { fail: false }
  engine(on, calls, [], run)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  run.fail = true
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await $.ui.press({ plugin: 'taskboard', key: 'pane-sync' })
  expect(calls.at(-1)?.slice(-2)).toEqual(['sync', '--board'])
  expect((await ui.find({ type: 'Text', text: /failed/ }))?.text).toBe('Last sync failed: gh: not logged in')
  await ui.unmount()
})
