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

const task = (id: string, stage: string) => ({
  id,
  title: `Title ${id}`,
  stage,
  kind: 'cycle',
  owner: null,
  unsubscribed: false,
  url: `https://linear.app/x/${id}`,
  parts: `${id} In Progress`,
  linkedBy: null,
  tree: null,
  actions: stage === 'needs-you' ? [{ type: 'needs-you', item: 'jr-1', reason: 'jr needs input' }] : [],
  prs:
    stage === 'iterate'
      ? [{ key: 'getsentry/sentry#131651', label: '#131651 draft', title: 'Clipboard fallback', url: 'https://github.com/getsentry/sentry/pull/131651', detail: '+12 −3 · 2 files · ✓40 ✗1 · warden: no problems', headAt: '2026-11-24T16:27:00Z' }]
      : [],
})

// The script builds this tree (scripts/lib/group.mjs); the pane only draws it.
const branch = (
  key: string,
  title: string,
  opts: { tasks?: string[]; prs?: object[]; children?: any[]; folded?: boolean; needsYou?: number; url?: string; caption?: string } = {},
): any => {
  const children = opts.children ?? []
  const tasks = opts.tasks ?? []
  const prs = opts.prs ?? []
  return {
    key,
    title,
    caption: opts.caption ?? null,
    url: opts.url ?? null,
    folded: opts.folded ?? false,
    count: tasks.length + prs.length + children.reduce((n: number, c: any) => n + c.count, 0),
    needsYou: (opts.needsYou ?? 0) + children.reduce((n: number, c: any) => n + c.needsYou, 0),
    children,
    tasks,
    prs,
  }
}
const DEPS_PR = {
  key: 'getsentry/sentry#127684',
  label: '#127684 open',
  title: 'chore(deps): bump tanstack-query',
  url: 'https://github.com/getsentry/sentry/pull/127684',
  detail: '+40 −40 · 2 files · ✓60',
  headAt: null,
}
const ADHOC_CAPTION = 'By repo, then how the PR involves you, then who opened it. Your PRs include bot PRs made for you.'
const LINKED = 'Linked: both PRs are named by 3 Claude sessions'
const UNSUB_PR = {
  key: 'getsentry/sentry#130433',
  label: '#130433 open',
  title: 'feat(onboarding): Drop the old wizard',
  url: 'https://github.com/getsentry/sentry/pull/130433',
  detail: '+5 −90 · 4 files · ✓52',
  headAt: null,
}
const SECTIONS = [
  branch('projects', 'Projects', {
    children: [
      branch('project:Agent handoff', 'Agent handoff'),
      branch('project:Agents', 'Agents', { tasks: ['VDY-423'] }),
      branch('project:Onboarding', 'Onboarding', { tasks: ['VDY-432', 'VDY-433'], needsYou: 1, url: 'https://linear.app/x/project/onboarding' }),
    ],
  }),
  branch('teams', 'Tickets with no project', { children: [branch('team:Value Discovery', 'Value Discovery', { tasks: ['VDY-381'] })] }),
  branch('adhoc', 'PRs with no ticket', {
    caption: ADHOC_CAPTION,
    children: [
      branch('repo:getsentry/sentry', 'getsentry/sentry', {
        children: [
          branch('repo:getsentry/sentry:team', 'Team review', {
            folded: true,
            children: [
              branch('repo:getsentry/sentry:team:app-frontend', 'app-frontend', {
                children: [branch('repo:getsentry/sentry:team:app-frontend:author:dependabot', 'dependabot', { prs: [DEPS_PR] })],
              }),
            ],
          }),
        ],
      }),
      // Your own PRs sit straight under Your PRs, with no author level.
      branch('repo:ryan953/dotFiles', 'ryan953/dotFiles', {
        children: [branch('repo:ryan953/dotFiles:mine', 'Your PRs', { tasks: ['local_dot'] })],
      }),
      branch('repo:ryan953/skills', 'ryan953/skills', {
        children: [
          branch('repo:ryan953/skills:direct', 'Review requested of you', {
            children: [branch('repo:ryan953/skills:direct:author:human', 'human', { tasks: ['skills#21'] })],
          }),
        ],
      }),
    ],
  }),
  branch('other', 'Other', { tasks: ['local_1'] }),
  // The script zeroes this section's needs-you count, so the fixture does too.
  branch('unsubscribed', 'Unsubscribed', { folded: true, tasks: ['getsentry/sentry#131412'], prs: [UNSUB_PR] }),
]

const BOARD = {
  generatedAt: '2026-11-23T23:09:22.202Z',
  counts: { open: 3, needsYou: 1, followUp: 1, check: 0, archive: 0, close: 0, nudge: 1, queue: 38, backlog: 46, unsubscribed: 2 },
  sections: SECTIONS,
  tasks: [
    task('VDY-433', 'iterate'),
    task('VDY-432', 'needs-you'),
    { ...task('VDY-381', 'follow-up'), actions: [{ type: 'follow-up', item: 'cc-1', reason: 'file the Safari ticket' }] },
    { ...task('skills#21', 'review'), url: 'https://github.com/ryan953/skills/pull/21' },
    {
      ...task('local_dot', 'iterate'),
      title: 'chore(agents): Install ryan953/skills from the taskboard branch',
      prs: [
        { key: 'ryan953/dotfiles#18', label: 'ryan953/dotFiles#18 draft', title: 'Install skills', url: 'https://github.com/ryan953/dotFiles/pull/18', detail: null, headAt: null },
        { key: 'ryan953/skills#20', label: 'ryan953/skills#20 draft', title: 'Taskboard', url: 'https://github.com/ryan953/skills/pull/20', detail: null, headAt: null },
      ],
      linkedBy: LINKED,
    },
    // Your own approved PR that you unsubscribed from: it could merge, but it is out of sight.
    { ...task('getsentry/sentry#131412', 'merge'), unsubscribed: true, url: 'https://github.com/getsentry/sentry/pull/131412' },
    { ...task('local_1', 'adhoc'), title: 'Dashboard: number of tests', url: 'https://junior-prod.sentry.dev/conversations/local_1', parts: 'jr:active' },
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

type Run = { fail: boolean; board?: object; store?: Record<string, unknown> }

function engine(
  on: any,
  calls: string[][],
  prompts: string[],
  run: Run = { fail: false },
  sessions: string[] = ['cli-main'],
  looks: any[] = [],
  statuses: (string | undefined)[] = [],
  theme = { refusesStyle: false },
) {
  mock.store(on, { enabledSessions: sessions, ...run.store })
  on('theme.set', (_: unknown, e: any) => {
    looks.push(e)
    return theme.refusesStyle && e.style ? { deny: 'style is not supported' } : { value: { isDrawn: true, requestId: 'theme' } }
  })
  on('ui.status', (_: unknown, e: any) => {
    statuses.push(e.text)
    return { value: undefined }
  })
  on('session.id', () => ({ value: 'cli-main' }))
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'You are Claude Code.', scope: 'shared' }] }))
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
      : { value: { exitCode: 0, stdout: JSON.stringify(run.board ?? BOARD), stderr: '' } }
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

const CLEANUP_BOARD = { ...BOARD, counts: { ...BOARD.counts, check: 2, archive: 1 } }

// The desktop app's session tools as the mod calls them, over a list of known sessions.
function desktop(on: any, known: Record<string, { isArchived: boolean }>, refusal?: string) {
  const tools: any[] = []
  const sends: any[] = []
  const toasts: string[] = []
  on('tool.call', (_: unknown, e: any) => {
    tools.push(e)
    if (e.tool === 'mcp__ccd_session_mgmt__get_session') {
      const s = known[e.session_id]
      return s
        ? { result: {}, text: JSON.stringify({ sessionId: e.session_id, title: 'Taskboard clean-up', isArchived: s.isArchived }) }
        : { result: {}, text: `No session ${e.session_id}`, isError: true }
    }
    if (e.tool === 'mcp__ccd_session__start_session') {
      if (refusal) return { result: {}, text: refusal }
      known['local_new-1'] = { isArchived: false }
      return { result: {}, text: 'Started session "Taskboard clean-up" (session_id: local_new-1, name: taskboard-cleanup). It runs on its own.' }
    }
    return { result: {}, text: 'Detached.' }
  })
  on('session.send', (_: unknown, e: any) => {
    sends.push(e)
    return { isDelivered: true }
  })
  on('ui.toast', (_: unknown, e: any) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  return { tools, sends, toasts, names: () => tools.map(t => t.tool.split('__').pop()) }
}

test('Clean up with no kept session starts one, keeps it, and runs nothing here', async ($, on) => {
  const calls: string[][] = []
  const prompts: string[] = []
  engine(on, calls, prompts, { fail: false, board: CLEANUP_BOARD })
  const app = desktop(on, {})
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  await $.ui.press({ plugin: 'taskboard', key: 'pane-cleanup' })
  expect(prompts).toEqual([])
  expect(app.names()).toEqual(['start_session', 'detach_session'])
  const start = app.tools[0]
  expect(start).toMatchObject({ initiation: 'user_asked', title: 'Taskboard clean-up', context: 'fresh' })
  // A fresh session reads only this, so the request names the skill and the whole flow.
  expect(start.prompt).toMatch(/^\/taskboard clean up/)
  expect(start.prompt).toMatch(/`ask`, then `checked`/)
  expect(start.consent).toBe('The user pressed "Clean up (3)" on the Taskboard pane.')
  expect(app.tools[1]).toMatchObject({ session_id: 'local_new-1' })
  expect(calls.at(-1)?.slice(-3)).toEqual(['manager', 'add', 'local_new-1'])
  expect(app.toasts).toEqual(['Started "Taskboard clean-up" for the clean-up.'])

  // The store keeps it, so the next press goes to the same session.
  app.tools.length = 0
  await $.ui.press({ plugin: 'taskboard', key: 'pane-cleanup' })
  expect(app.names()).toEqual(['get_session'])
  expect(app.sends.map(m => m.to)).toEqual(['local_new-1'])
  await ui.unmount()
})

test('Clean up sends the request to the kept session while it is live', async ($, on) => {
  const calls: string[][] = []
  const prompts: string[] = []
  engine(on, calls, prompts, { fail: false, board: CLEANUP_BOARD, store: { cleanupSession: { id: 'local_kept', title: 'Taskboard clean-up' } } })
  const app = desktop(on, { local_kept: { isArchived: false } })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  calls.length = 0

  await $.ui.press({ plugin: 'taskboard', key: 'pane-cleanup' })
  expect(prompts).toEqual([])
  expect(app.names()).toEqual(['get_session'])
  expect(app.sends).toHaveLength(1)
  expect(app.sends[0].to).toBe('local_kept')
  expect(app.sends[0].text).toMatch(/^\/taskboard clean up/)
  expect(calls).toEqual([])
  expect(app.toasts).toEqual(['Clean-up sent to "Taskboard clean-up".'])
  await ui.unmount()
})

async function replaced($: any, on: any, known: Record<string, { isArchived: boolean }>) {
  const calls: string[][] = []
  engine(on, calls, [], { fail: false, board: CLEANUP_BOARD, store: { cleanupSession: { id: 'local_kept', title: 'Taskboard clean-up' } } })
  const app = desktop(on, known)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  await $.ui.press({ plugin: 'taskboard', key: 'pane-cleanup' })
  expect(app.sends).toEqual([])
  expect(app.names()).toEqual(['get_session', 'start_session', 'detach_session'])
  expect(calls.map(c => c.slice(-3)).filter(c => c[0] === 'manager')).toEqual([
    ['manager', 'remove', 'local_kept'],
    ['manager', 'add', 'local_new-1'],
  ])
  expect(app.toasts).toEqual(['Started "Taskboard clean-up" for the clean-up.'])
  await ui.unmount()
}

test('Clean up replaces a kept session that was archived', ($, on) => replaced($, on, { local_kept: { isArchived: true } }))

test('Clean up replaces a kept session that is gone', ($, on) => replaced($, on, {}))

test('a refused start shows the whole reason in the pane and keeps nothing', async ($, on) => {
  const calls: string[][] = []
  const prompts: string[] = []
  engine(on, calls, prompts, { fail: false, board: CLEANUP_BOARD })
  const refusal = 'Nothing was started. Before this can work, the user needs to trust the folder the new session would run in.'
  const app = desktop(on, {}, refusal)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  await $.ui.press({ plugin: 'taskboard', key: 'pane-cleanup' })
  expect(prompts).toEqual([])
  expect(app.names()).toEqual(['start_session'])
  expect(calls.some(c => c.includes('manager'))).toBe(false)
  expect(app.toasts).toEqual(['Clean-up went nowhere. The Taskboard pane says why.'])
  const shown = await ui.find({ type: 'Text', text: /^Clean-up not started/ })
  expect(shown?.text).toBe(`Clean-up not started: ${refusal}`)
  expect(shown?.props.color).toBe('error')
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
  expect((await ui.find({ type: 'Text', text: /^taskboard:/ }))?.text).toMatch(/1 to nudge$/)
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

test('a manager session is marked by a striped ground, a message frame, a status line and a band badge', async ($, on) => {
  const looks: any[] = []
  const statuses: (string | undefined)[] = []
  engine(on, [], [], { fail: false }, [], looks, statuses)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(statuses).toEqual([undefined])

  await $.command.run({ command: 'board', args: 'on', ...TYPED })
  const manager = looks.at(-1)
  // A still, tiled pattern in palette names, so it follows light and dark mode.
  expect(manager.backdrop.vector.repeat).toBe(true)
  expect(manager.backdrop.gradient).toBeUndefined()
  const colors = manager.backdrop.vector.paths.map((p: any) => p.color)
  expect(colors).toEqual(['surface-0', 'bg-pro'])
  expect(manager.style.UserMessage.borderColor).toBe('border-pro')
  expect(statuses.at(-1)).toBe('◆ Taskboard manager')

  for (const surface of ['terminal', 'desktop'] as const) {
    const band = await $.ui.mount({ plugin: 'taskboard', component: 'AbovePrompt', props: { hasSurvey: false }, surface } as any)
    const texts = (await band.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts[0]).toBe(' Manager ')
    expect(texts[1]).toMatch(/^taskboard:/)
    await band.unmount()
  }

  await $.command.run({ command: 'board', args: 'off', ...TYPED })
  expect(statuses.at(-1)).toBeUndefined()
  expect(looks.at(-1).style).toBeUndefined()
})

test('a build that refuses the message style still gets the striped ground', async ($, on) => {
  const looks: any[] = []
  engine(on, [], [], { fail: false }, ['cli-main'], looks, [], { refusesStyle: true })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(looks.map(l => Boolean(l.style))).toEqual([true, false])
  expect(looks.at(-1).backdrop.vector.repeat).toBe(true)
})

test('the tree draws on every surface, narrow and wide', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  for (const surface of ['terminal', 'desktop'] as const) {
    for (const bodyColumns of [60, 120, 180]) {
      const ui = await $.ui.mount({ ...PANE, props: { ...PANE.props, bodyColumns }, surface })
      for (const text of ['Projects', 'Onboarding', 'Tickets with no project', 'Value Discovery', 'PRs with no ticket', 'ryan953/skills', 'Other']) {
        expect(await ui.find({ type: 'Text', text: new RegExp(`^${text}$`) })).toBeTruthy()
      }
      await ui.unmount()
    }
  }
})

test('projects, then tickets by team, then PRs by repo, role and author, then other; most urgent first', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
  const at = (s: string) => texts.indexOf(s)
  const order = [
    'Projects',
    'Agents',
    'Onboarding',
    'Tickets with no project',
    'Value Discovery',
    'PRs with no ticket',
    ADHOC_CAPTION,
    'getsentry/sentry',
    'Team review',
    'ryan953/dotFiles',
    'Your PRs',
    'local_dot',
    'ryan953/skills',
    'Review requested of you',
    'human',
    'Other',
  ].map(at)
  expect(order.every(n => n >= 0)).toBe(true)
  expect(order).toEqual([...order].sort((a, b) => a - b))
  // Each ticket sits under its project with its PR inside the card.
  expect(at('VDY-423')).toBeGreaterThan(at('Agents'))
  const all = await ui.findAll({})
  const pos = (f: (el: (typeof all)[number]) => boolean) => all.findIndex(f)
  const pr = pos(el => el.type === 'Link' && el.text === '#131651 draft')
  expect(pr).toBeGreaterThan(pos(el => el.key === 'row:VDY-433'))
  expect(pr).toBeLessThan(pos(el => el.key === 'row:VDY-381'))
  expect(at('VDY-432')).toBeLessThan(at('VDY-433'))
  expect(texts[at('VDY-432') + 1]).toBe('Needs you')
  // A project you belong to with no ticket of yours still shows.
  expect(texts[at('Agent handoff') + 2]).toBe('No open tickets of yours')
  // A card whose PRs span repos says what ties them, under its PR links.
  const linked = pos(el => el.type === 'Text' && el.text === LINKED)
  expect(linked).toBeGreaterThan(pos(el => el.type === 'Link' && el.text === 'ryan953/skills#20 draft'))
  expect(linked).toBeLessThan(pos(el => el.key === 'overview:local_dot'))
  // A lone session keeps its card, with its buttons, under Other.
  expect(at('local_1')).toBeGreaterThan(at('Other'))
  await $.ui.press({ plugin: 'taskboard', key: 'overview:local_1' })
  await ui.unmount()
})

test('team review starts folded, keeps its count, and opens to the lone PRs with their detail', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    const has = async (text: string) => Boolean(await ui.find({ type: 'Text', text: new RegExp(`^${text}$`) }))
    const marker = async (key: string) => (await ui.find({ type: 'Button', key: `fold:${key}` }))?.props.label
    expect(await marker('repo:getsentry/sentry:team')).toBe('▶')
    expect(await has('Team review')).toBe(true)
    expect(await has('app-frontend')).toBe(false)
    expect(await has('chore\\(deps\\): bump tanstack-query')).toBe(false)

    await $.ui.press({ plugin: 'taskboard', key: 'fold:repo:getsentry/sentry:team' })
    expect(await marker('repo:getsentry/sentry:team')).toBe('▼')
    expect(await has('dependabot')).toBe(true)
    expect(await has('chore\\(deps\\): bump tanstack-query')).toBe(true)
    expect(await has('\\+40 −40 · 2 files · ✓60')).toBe(true)
    await $.ui.press({ plugin: 'taskboard', key: 'fold:repo:getsentry/sentry:team' })
    expect(await has('dependabot')).toBe(false)
    await ui.unmount()
  }
})

test('every heading folds its rows and unfolds them again, and a folded heading still says it needs you', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    const has = async (text: string) => Boolean(await ui.find({ type: 'Text', text: new RegExp(`^${text}$`) }))
    const marker = async (key: string) => (await ui.find({ type: 'Button', key: `fold:${key}` }))?.props.label

    // The marker is the only control and shows only the glyph; the title appears once, as text.
    expect(await marker('projects')).toBe('▼')
    expect(await ui.findAll({ type: 'Button', text: /Projects/ })).toHaveLength(0)
    expect(await ui.findAll({ type: 'Text', text: /^Projects$/ })).toHaveLength(1)
    // An open heading draws a rail down the side of what it holds; a folded one has nothing to mark.
    const rail = async (key: string) => {
      const p = (await ui.find({ type: 'Box', key: `rail:${key}` }))?.props
      return p && { borderStyle: p.borderStyle, marginLeft: p.marginLeft }
    }
    // The rail starts at the middle of the fold button's gutter, so the line runs under its center.
    expect(await rail('projects')).toEqual({ borderStyle: 'quote', marginLeft: 2 })
    await $.ui.press({ plugin: 'taskboard', key: 'fold:projects' })
    expect(await marker('projects')).toBe('▶')
    expect(await rail('projects')).toBeUndefined()
    // A folded heading keeps its title, count and needs-you count.
    expect(await has('Projects')).toBe(true)
    expect(await has('3')).toBe(true)
    expect(await has('1 need you')).toBe(true)
    expect(await has('Agents')).toBe(false)
    expect(await has('VDY-433')).toBe(false)
    expect(await has('VDY-381')).toBe(true)
    await $.ui.press({ plugin: 'taskboard', key: 'fold:projects' })
    expect(await has('VDY-433')).toBe(true)
    expect(await marker('projects')).toBe('▼')

    await $.ui.press({ plugin: 'taskboard', key: 'fold:project:Agents' })
    expect(await has('Agents')).toBe(true)
    expect(await has('VDY-423')).toBe(false)
    expect(await has('VDY-433')).toBe(true)
    await $.ui.press({ plugin: 'taskboard', key: 'fold:project:Agents' })
    expect(await has('VDY-423')).toBe(true)

    for (const key of ['team:Value Discovery', 'repo:ryan953/skills:direct:author:human', 'other']) {
      await $.ui.press({ plugin: 'taskboard', key: `fold:${key}` })
    }
    expect(await has('VDY-381')).toBe(false)
    expect(await has('skills#21')).toBe(false)
    expect(await has('local_1')).toBe(false)
    for (const key of ['team:Value Discovery', 'repo:ryan953/skills:direct:author:human', 'other']) {
      await $.ui.press({ plugin: 'taskboard', key: `fold:${key}` })
    }
    expect(await has('skills#21')).toBe(true)
    await ui.unmount()
  }
})

test('stage filters add up, All others is their inverse, and All clears them', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    const has = async (text: string) => Boolean(await ui.find({ type: 'Text', text: new RegExp(`^${text}$`) }))
    const chip = async (f: string) => (await ui.find({ type: 'Button', key: `filter:${f}` }))?.props
    const press = (f: string) => $.ui.press({ plugin: 'taskboard', key: `filter:${f}` })

    expect((await chip('needs-you'))?.label).toBe('Needs you 1')
    expect((await chip('follow-up'))?.label).toBe('Follow-up 1')
    expect((await chip('merge'))?.label).toBe('Ready to merge 0')
    expect((await chip('others'))?.label).toMatch(/^All others \d+$/)
    expect((await chip('all'))?.variant).toBe('primary')

    await press('needs-you')
    expect((await chip('needs-you'))?.variant).toBe('primary')
    expect((await chip('all'))?.variant).toBeUndefined()
    expect(await has('VDY-432')).toBe(true)
    expect(await has('VDY-433')).toBe(false)
    expect(await has('VDY-381')).toBe(false)
    // A group with nothing left in it is gone, heading and all.
    expect(await has('Other')).toBe(false)

    await press('follow-up')
    expect(await has('VDY-432')).toBe(true)
    expect(await has('VDY-381')).toBe(true)
    expect(await has('VDY-433')).toBe(false)

    await press('all')
    expect(await has('VDY-433')).toBe(true)
    expect((await chip('all'))?.variant).toBe('primary')

    await press('others')
    expect(await has('VDY-433')).toBe(true)
    expect(await has('VDY-423')).toBe(true)
    expect(await has('local_1')).toBe(true)
    expect(await has('VDY-432')).toBe(false)
    expect(await has('VDY-381')).toBe(false)
    // Lone PRs have no stage, so they count as others.
    expect(await has('Team review')).toBe(true)

    await press('others')
    await press('merge')
    expect(await has('Nothing matches these filters.')).toBe(true)
    await press('all')
    await ui.unmount()
  }
})

test('unsubscribed PRs start folded at the bottom, out of every count, and open on press', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    const has = async (text: string) => Boolean(await ui.find({ type: 'Text', text: new RegExp(`^${text}$`) }))
    const marker = async (key: string) => (await ui.find({ type: 'Button', key: `fold:${key}` }))?.props.label
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts.indexOf('Unsubscribed')).toBeGreaterThan(texts.indexOf('Other'))
    expect(await marker('unsubscribed')).toBe('▶')
    expect(texts[texts.indexOf('Unsubscribed') + 1]).toBe('2')
    expect(await has('getsentry/sentry#131412')).toBe(false)
    expect(await has('feat\\(onboarding\\): Drop the old wizard')).toBe(false)
    // Its task could merge, but no filter counts it.
    expect((await ui.find({ type: 'Button', key: 'filter:merge' }))?.props.label).toBe('Ready to merge 0')
    expect(await has('3 open · 38 in review queue · 46 filed, unlinked · 2 unsubscribed')).toBe(true)

    await $.ui.press({ plugin: 'taskboard', key: 'fold:unsubscribed' })
    expect(await marker('unsubscribed')).toBe('▼')
    expect(await has('getsentry/sentry#131412')).toBe(true)
    expect(await has('feat\\(onboarding\\): Drop the old wizard')).toBe(true)
    expect(await has('\\+5 −90 · 4 files · ✓52')).toBe(true)

    // A filter shows only what asks for you, so the section is gone while one is picked.
    await $.ui.press({ plugin: 'taskboard', key: 'filter:merge' })
    expect(await has('Unsubscribed')).toBe(false)
    expect(await has('getsentry/sentry#131412')).toBe(false)
    await $.ui.press({ plugin: 'taskboard', key: 'filter:all' })
    await $.ui.press({ plugin: 'taskboard', key: 'fold:unsubscribed' })
    await ui.unmount()
  }
})

test('the band leaves unsubscribed tasks out of its counts', async ($, on) => {
  engine(on, [], [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ plugin: 'taskboard', component: 'AbovePrompt', props: { hasSurvey: false }, surface: 'desktop' } as any)
  expect((await ui.find({ type: 'Text', text: /^taskboard:/ }))?.text).toBe('taskboard: 1 need you · 1 follow-ups · 2 iterate · 1 review · 1 to nudge')
  await ui.unmount()
})

test('the system prompt carries the manager section only while the board is on', async ($, on) => {
  engine(on, [], [], { fail: false }, [])
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const input = { model: 'claude-opus-5-5', promptModel: 'claude-opus-5-5', surfaces: ['desktop'], tools: [], outputStyle: null, traits: [] } as const
  const ids = async () => (await $.prompt.compose(input)).sections.map(s => s.id)
  expect(await ids()).toEqual(['intro'])

  await $.command.run({ command: 'board', args: 'on', ...TYPED })
  const on1 = await $.prompt.compose(input)
  expect(on1.sections.map(s => s.id)).toEqual(['intro', 'taskboard:manager'])
  const section = on1.sections.at(-1)!
  // It varies by session, so it sits after the cache boundary.
  expect(section.scope).toBe('session')
  expect(section.text).toMatch(/Manage section of the taskboard skill/)
  expect(section.text).toMatch(/Never merge a PR/)
  expect(section.text).toMatch(/Do not judge the quality/)

  await $.command.run({ command: 'board', args: 'off', ...TYPED })
  expect(await ids()).toEqual(['intro'])
})

// jr as its MCP connector answers, over a list of messages per conversation.
const JR = 'mcp__381edf2d-e9df-4970-9a5a-0fabca4cd665'
const jrCursor = (id: string, seq: number) => `${btoa(JSON.stringify({ conversationId: id, seq, version: 1 })).replace(/=+$/, '')}.sig`

function jr(on: any, conversations: Record<string, any[]>) {
  const marks: any[] = []
  mock.store(on, {})
  on('tool.call', (_: unknown, e: any) => {
    const id = e.conversationId ?? 'local:web:new'
    const list = (conversations[id] ??= [])
    const tail = list.at(-1)?.seq ?? -1
    const answer = (v: object) => ({ result: {}, text: JSON.stringify(v) })
    switch (e.tool.split('__').pop()) {
      case 'createConversation':
      case 'sendMessage': {
        const messageId = `api-msg:${list.length}`
        list.push({ seq: tail + 1, messageId, role: 'user', author: 'Ryan' })
        return answer({ conversationId: id, messageId, pendingMessages: [{ messageId }], cursor: jrCursor(id, tail) })
      }
      case 'getConversation':
        return answer({ conversation: { conversationId: id }, messages: list, cursor: jrCursor(id, tail + 2) })
      case 'listConversationMessages':
        return answer({ messages: list })
      case 'markConversationRead':
        marks.push(e)
        return answer({ lastReadSeq: e.lastReadSeq })
    }
    return { result: {}, text: 'unknown tool', isError: true }
  })
  return marks
}

const reply = (seq: number, to: string) => ({ seq, messageId: `turn_${to.replace(/:/g, '_')}:assistant:1`, role: 'assistant' })

test('a jr conversation Claude started is marked read up to the newest reply it read', async ($, on) => {
  const conversations: Record<string, any[]> = {}
  const marks = jr(on, conversations)
  await $.tool.call({ tool: `${JR}__createConversation`, message: 'Is anything left?' })
  conversations['local:web:new']!.push(reply(11, 'api-msg:0'))

  await $.tool.call({ tool: `${JR}__getConversation`, conversationId: 'local:web:new' })
  expect(marks).toEqual([expect.objectContaining({ tool: `${JR}__markConversationRead`, conversationId: 'local:web:new', lastReadSeq: 11 })])

  // Nothing new since: no second call.
  await $.tool.call({ tool: `${JR}__listConversationMessages`, conversationId: 'local:web:new' })
  expect(marks.length).toBe(1)
})

test('a jr conversation the user chats in is never marked read', async ($, on) => {
  const slack = 'slack:D0AN20G5WMS:1795468391.929599'
  const conversations: Record<string, any[]> = {
    [slack]: [{ seq: 4, messageId: 'slack:1795468391.929599', role: 'user' }, reply(9, 'slack:1795468391.929599')],
  }
  const marks = jr(on, conversations)
  await $.tool.call({ tool: `${JR}__getConversation`, conversationId: slack })
  await $.tool.call({ tool: `${JR}__listConversationMessages`, conversationId: slack })
  expect(marks).toEqual([])
})

test('a jr conversation goes back to the user at the first message Claude did not cause', async ($, on) => {
  const slack = 'slack:D0AN20G5WMS:1795467864.789489'
  const conversations: Record<string, any[]> = { [slack]: [{ seq: 2, messageId: 'slack:old', role: 'user' }, reply(5, 'slack:old')] }
  const marks = jr(on, conversations)
  await $.tool.call({ tool: `${JR}__sendMessage`, conversationId: slack, message: 'Is anything left?' })
  // Claude's question (6), jr's answer (8), then the user types in Slack (9) and jr answers them (12).
  conversations[slack]!.push(reply(8, 'api-msg:2'), { seq: 9, messageId: 'slack:new', role: 'user' }, reply(12, 'slack:new'))

  await $.tool.call({ tool: `${JR}__getConversation`, conversationId: slack })
  expect(marks.map(m => m.lastReadSeq)).toEqual([8])

  conversations[slack]!.push(reply(14, 'slack:new'))
  await $.tool.call({ tool: `${JR}__getConversation`, conversationId: slack })
  expect(marks.length).toBe(1)
})
