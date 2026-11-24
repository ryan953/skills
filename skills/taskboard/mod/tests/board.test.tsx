import { expect, mock, test } from 'claude-code/testing'

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

const team = (project: string | null) => ({ kind: 'team', team: 'Value Discovery', project }) as const

const task = (id: string, stage: string, group: object = team('Onboarding')) => ({
  id,
  title: `Title ${id}`,
  stage,
  kind: 'cycle',
  owner: null,
  url: `https://linear.app/x/${id}`,
  group,
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
    task('VDY-433', 'iterate'),
    task('VDY-432', 'needs-you'),
    { ...task('VDY-381', 'follow-up', team(null)), actions: [{ type: 'follow-up', item: 'cc-1', reason: 'file the Safari ticket' }] },
    { ...task('skills#21', 'review', { kind: 'repo', repo: 'ryan953/skills' }), url: 'https://github.com/ryan953/skills/pull/21' },
    {
      ...task('VDY-423', 'fix', team('Agents')),
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

// What the engine stamps on a command the person typed at the prompt.
const TYPED = { origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 80 } } as const

const WORKERS = [
  { session: 'cc-9', title: 'VDY-433', task: 'VDY-433', stage: 'iterate', isOwner: true, turnStartedAt: '2026-11-24T16:24:00Z' },
]

const OVERVIEW_DATA = {
  id: 'VDY-423',
  title: 'Agent progress polls forever',
  stage: 'fix',
  kind: 'cycle',
  owner: null,
  ticket: {
    id: 'VDY-423',
    title: 'Agent progress polls forever',
    url: 'https://linear.app/x/VDY-423',
    status: 'In Progress',
    priority: 'Low',
    assignee: 'Ryan',
    labels: ['Bug'],
    project: 'Onboarding',
    cycle: 'Cycle 25',
    team: 'Value Discovery (VDY)',
    branch: 'ryan953/vdy-423',
    description: 'Polls every **5s** forever.',
  },
  comments: [{ author: 'jr', at: '2026-11-20T10:00:00Z', body: 'Validated on dev.' }],
  moreComments: 2,
  tree: {
    self: 'VDY-423',
    parent: { id: 'VDY-376', title: 'Parent', url: 'https://linear.app/x/VDY-376', progress: { done: 18, total: 73 } },
    progress: null,
    children: [],
    siblings: [{ id: 'VDY-455', title: 'Labels mix grammar', url: 'https://linear.app/x/VDY-455', state: 'Triage', prs: [], task: null, canDispatch: true, isDone: false }],
  },
  items: [{ key: 'VDY-423', type: 'linear', label: 'VDY-423 In Progress', title: 'Agent progress polls forever', url: 'https://linear.app/x/VDY-423', detail: null }],
  actions: [],
}

function engine(on: any, calls: string[][], prompts: string[], run = { fail: false }, sessions: string[] = ['cli-main'], looks: any[] = []) {
  mock.store(on, { enabledSessions: sessions })
  on('theme.set', (_: unknown, e: any) => {
    looks.push(e)
    return { value: { isDrawn: true, requestId: 'theme' } }
  })
  on('session.id', () => ({ value: 'cli-main' }))
  // Refusing the first period ends the interval, so no timer runs in a test.
  on('clock.every', () => ({ deny: 'no timer in tests' }))
  on('command.register', () => ({ value: { command: 'board' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_: unknown, e: any) => ({ cwd: e.cwd }))
  on('process.hookEnv', () => ({ value: {} }))
  on('clock.now', () => ({ value: Date.parse('2026-11-24T16:30:00Z') }))
  on('process.run', (_: unknown, e: any) => {
    calls.push([...e.argv])
    if (e.argv.includes('detail')) return { value: { exitCode: 0, stdout: JSON.stringify(OVERVIEW_DATA), stderr: '' } }
    if (e.argv.includes('manager')) return { value: { exitCode: 0, stdout: 'managers: local_main. Run "sync".', stderr: '' } }
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
  expect(await ui.find({ type: 'Text', text: /^Needs you$/ })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /^Iterate$/ })).toBeTruthy()
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

test('Overview loads the task on demand and shows properties, comments and siblings', async ($, on) => {
  const calls: string[][] = []
  const prompts: string[] = []
  engine(on, calls, prompts)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const board = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await $.ui.press({ plugin: 'taskboard', key: 'overview:VDY-423' })
  expect(calls.at(-1)?.slice(-2)).toEqual(['detail', 'VDY-423'])
  await board.unmount()

  const ui = await $.ui.mount({ ...PANE, requestId: 'taskboard-overview', props: { ...PANE.props, title: 'Task overview' }, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /^Value Discovery/ }))?.text).toBe('Value Discovery (VDY)')
  expect((await ui.find({ type: 'Text', text: /^jr ·/ }))?.text).toBe('jr · 2026-11-20')
  expect((await ui.find({ type: 'Text', text: /^Siblings/ }))?.text).toBe('Siblings (1)')
  await $.ui.press({ plugin: 'taskboard', key: 'ov-dispatch:VDY-455' })
  expect(prompts).toEqual(['/taskboard dispatch VDY-455'])
  await ui.unmount()
})

test('a session that is not enabled draws no band and runs nothing', async ($, on) => {
  const calls: string[][] = []
  engine(on, calls, [], { fail: false }, [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(calls).toEqual([])

  const band = await $.ui.mount({ plugin: 'taskboard', component: 'AbovePrompt', props: { hasSurvey: false }, surface: 'desktop' } as any)
  expect(await band.find({ type: 'Text', text: /^taskboard:/ })).toBeFalsy()
  await band.unmount()
  const pane = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await pane.find({ type: 'Text', text: /off in this session/ }))?.text).toMatch(/^The taskboard is off in this session/)
  await pane.unmount()
})

test('/board on enables this session and marks it a manager; /board off stops it', async ($, on) => {
  const calls: string[][] = []
  engine(on, calls, [], { fail: false }, ['cli-other'])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(calls).toEqual([])

  await $.command.run({ command: 'board', args: 'on', ...TYPED })
  expect(calls[0]?.slice(-3)).toEqual(['manager', 'add', 'cli-main'])
  expect(calls[1]?.slice(-2)).toEqual(['show', '--board'])
  const band = await $.ui.mount({ plugin: 'taskboard', component: 'AbovePrompt', props: { hasSurvey: false }, surface: 'desktop' } as any)
  expect((await band.find({ type: 'Text', text: /^taskboard:/ }))?.text).toMatch(/1 need you/)
  await band.unmount()
  // The store keeps the choice, so a restart starts the board again.
  calls.length = 0
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(calls[0]?.slice(-2)).toEqual(['show', '--board'])

  await $.command.run({ command: 'board', args: 'off', ...TYPED })
  expect(calls.at(-1)?.slice(-3)).toEqual(['manager', 'remove', 'cli-main'])
  calls.length = 0
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(calls).toEqual([])
  const after = await $.ui.mount({ plugin: 'taskboard', component: 'AbovePrompt', props: { hasSurvey: false }, surface: 'desktop' } as any)
  expect(await after.find({ type: 'Text', text: /^taskboard:/ })).toBeFalsy()
  await after.unmount()
})

test('the manager session and the other sessions get different backdrops', async ($, on) => {
  const looks: any[] = []
  engine(on, [], [], { fail: false }, [], looks)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run({ command: 'board', args: 'on', ...TYPED })
  await $.command.run({ command: 'board', args: 'off', ...TYPED })
  expect(looks.length).toBe(3)
  const [worker, manager, back] = looks.map(l => JSON.stringify(l.backdrop))
  expect(manager).not.toBe(worker)
  expect(back).toBe(worker)
})

test('the grid draws on every surface, narrow and wide', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  for (const surface of ['terminal', 'desktop'] as const) {
    for (const bodyColumns of [60, 120, 180]) {
      const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, bodyColumns }, surface })
      expect(await ui.find({ type: 'Text', text: /^Value Discovery$/ })).toBeTruthy()
      expect(await ui.find({ type: 'Text', text: /^ryan953\/skills$/ })).toBeTruthy()
      await ui.unmount()
    }
  }
})

test('tasks group by team and project, PRs with no ticket by repo, most urgent first', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  const at = (s: string) => texts.indexOf(s)
  // Projects sort by name with the ticket-less ones last, and repos come after every team.
  const order = ['Value Discovery', 'Agents', 'Onboarding', 'No project', 'ryan953/skills'].map(at)
  expect(order.every(n => n >= 0)).toBe(true)
  expect(order).toEqual([...order].sort((a, b) => a - b))
  // Inside a project, the task that needs the user comes before one being iterated on.
  expect(at('VDY-432')).toBeLessThan(at('VDY-433'))
  expect(texts[at('VDY-432') + 1]).toBe('Needs you')
  await ui.unmount()
})
