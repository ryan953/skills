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
  tree: null,
  actions: stage === 'needs-you' ? [{ type: 'needs-you', item: 'jr-1', reason: 'jr needs input' }] : [],
  prs:
    stage === 'iterate'
      ? [{ key: 'getsentry/sentry#131651', label: '#131651 draft', url: 'https://github.com/getsentry/sentry/pull/131651', detail: '+12 −3 · 2 files · ✓40 ✗1 · warden: no problems', headAt: '2026-11-24T16:27:00Z' }]
      : [],
})

const BOARD = {
  generatedAt: '2026-11-23T23:09:22.202Z',
  counts: { open: 3, needsYou: 1, followUp: 1, check: 0, archive: 0, close: 0, queue: 38, backlog: 46 },
  tasks: [
    task('VDY-432', 'needs-you'),
    task('VDY-433', 'iterate'),
    { ...task('VDY-381', 'follow-up'), actions: [{ type: 'follow-up', item: 'cc-1', reason: 'file the Safari ticket' }] },
    {
      ...task('VDY-423', 'fix'),
      tree: {
        self: 'VDY-423',
        parent: { id: 'VDY-376', title: 'Parent', url: 'https://linear.app/x/VDY-376', progress: { done: 18, total: 73 } },
        progress: { done: 1, total: 3 },
        children: [{ id: 'VDY-12', title: 'Child', url: 'https://linear.app/x/VDY-12', state: 'Triage', prs: [], task: null, canDispatch: true }],
        siblings: [],
        moreSiblings: 0,
      },
    },
  ],
}

const WORKERS = [
  { session: 'cc-9', title: 'VDY-433', task: 'VDY-433', stage: 'iterate', isOwner: true, turnStartedAt: '2026-11-24T16:24:00Z' },
]

function engine(on: any, calls: string[][], prompts: string[], run = { fail: false }) {
  // Refusing the first period ends the interval, so no timer runs in a test.
  on('clock.every', () => ({ deny: 'no timer in tests' }))
  on('command.register', () => ({ value: { command: 'board' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_: unknown, e: any) => ({ cwd: e.cwd }))
  on('process.hookEnv', () => ({ value: {} }))
  on('clock.now', () => ({ value: Date.parse('2026-11-24T16:30:00Z') }))
  on('process.run', (_: unknown, e: any) => {
    calls.push([...e.argv])
    if (e.argv.includes('workers')) return { value: { exitCode: 0, stdout: JSON.stringify(WORKERS), stderr: '' } }
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
  expect(calls.map(c => c.at(-1))).toEqual(['--board', 'workers'])
  expect(calls[0]?.slice(-2)).toEqual(['show', '--board'])

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /^needs-you/ }))?.text).toBe('needs-you (1)')
  expect((await ui.find({ type: 'Text', text: /^iterate/ }))?.text).toBe('iterate (1)')
  expect((await ui.find({ type: 'Text', text: /^Left to do/ }))?.text).toBe('Left to do: file the Safari ticket')
  expect((await ui.find({ type: 'Text', text: /warden/ }))?.text).toBe('+12 −3 · 2 files · ✓40 ✗1 · warden: no problems')
  expect((await ui.find({ type: 'Text', text: /^Implementing/ }))?.text).toBe('Implementing · 6m')
  expect((await ui.find({ type: 'Text', text: /^pushed/ }))?.text).toBe('pushed 3m ago')

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

test('the band counts running workers and how long the oldest has run', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ plugin: 'taskboard', component: 'AbovePrompt', props: { hasSurvey: false }, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /running/ }))?.text).toBe('1 worker running · 6m')
  await ui.unmount()
})

test('the tree opens on press and dispatches an untracked sub-issue', async ($, on) => {
  const prompts: string[] = []
  engine(on, [], prompts)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /^↑/ }))?.text).toBe('↑ VDY-376 · 18 of 73 done · sub-issues 1 of 3 done')
  expect(await ui.find({ type: 'Text', text: /^open sub-issues/ })).toBeFalsy()
  await $.ui.press({ plugin: 'taskboard', key: 'tree-toggle:VDY-423' })
  expect((await ui.find({ type: 'Text', text: /^open sub-issues/ }))?.text).toBe('open sub-issues (1)')
  await $.ui.press({ plugin: 'taskboard', key: 'dispatch-sub:VDY-423:VDY-12' })
  expect(prompts).toEqual(['/taskboard dispatch VDY-12'])
  await ui.unmount()
})
