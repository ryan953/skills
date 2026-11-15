import { expect, mock, test } from 'claude-code/testing'
import type { Engine, TestBody } from 'claude-code/testing'

type On = Parameters<TestBody>[1]

import { ANSWER } from './fixture'

const PANE = {
  plugin: 'pr-board',
  component: 'Pane',
  requestId: 'pr-board',
  props: {
    title: 'Pull requests',
    isFocused: false,
    bodyColumns: 80,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

// Stands for the engine: gh answers the fixture, the three skills are
// installed, and every command the board runs is recorded.
function engine(on: On, gh = { exitCode: 0, stdout: ANSWER, stderr: '' }) {
  const ran: string[][] = []
  const clock = mock.clock(on, { now: Date.parse('2026-11-15T12:00:00Z') })
  mock.store(on)
  mock.env(on, { HOME: '/home/me' })
  on('command.register', (_, e) => ({ value: { command: e.name } }))
  on('command.list', () => ({
    value: ['approve-pr', 'merge-pr', 'getsentry-tests'].map(name => ({
      name,
      description: name,
      source: 'user',
    })),
  }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('process.run', (_, e) => {
    ran.push([...e.argv])
    const out = e.argv[1] === 'api' ? gh : { exitCode: 0, stdout: '', stderr: '' }
    return { value: { ...out, isStdoutTruncated: false, isStderrTruncated: false } }
  })

  return { ran, clock }
}

async function start(
  $: Engine,
  { clock }: ReturnType<typeof engine>,
) {
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  await $.command.run({
    command: 'prs',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 120 },
  })
  await clock.settle()
}

test('the pane splits PRs into mine, other people and bots', async ($, on) => {
  await start($, engine(on))

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ key: 'group:mine' }))?.text).toContain('Mine (1)')
    expect((await ui.find({ key: 'group:other' }))?.text).toContain('Other people (1)')
    expect((await ui.find({ key: 'group:bot' }))?.text).toContain('Bots (1)')
    expect((await ui.find({ type: 'Text', text: /✗ CI/ }))?.text).toBe('✗ CI')
    expect((await ui.find({ type: 'Text', text: /Scope: Frontend/ }))).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /conflicts/ }))?.text).toBe('conflicts')
    await ui.unmount()
  }
})

test('a row opens to its actions, and approve runs the skill', async ($, on) => {
  const world = engine(on)
  const runs: string[] = []
  on('command.run', (_, e) => {
    if (e.command !== 'prs') runs.push(`${e.command} ${e.args}`)
    return { text: '' }
  })
  await start($, world)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    const url = 'https://github.com/getsentry/relay/pull/33'
    expect(await ui.find({ key: `approve:${url}` })).toBeUndefined()
    await ui.press({ key: `row:${url}` })
    expect(await ui.find({ key: `chat:${url}` })).toBeDefined()
    // Not sentry, so no getsentry tests button.
    expect(await ui.find({ key: `gst:${url}` })).toBeUndefined()
    await ui.press({ key: `approve:${url}` })
    await ui.press({ key: `row:${url}` })
    await ui.unmount()
  }
  expect(runs).toEqual([
    'approve-pr https://github.com/getsentry/relay/pull/33',
    'approve-pr https://github.com/getsentry/relay/pull/33',
  ])
})

test('the filter narrows every section', async ($, on) => {
  await start($, engine(on))

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.input({ key: 'filter', text: 'ci:fail' })
  expect((await ui.find({ key: 'group:mine' }))?.text).toContain('(1)')
  expect((await ui.find({ key: 'group:bot' }))?.text).toContain('(0)')
  await ui.press({ key: 'clear-filter' })
  expect((await ui.find({ key: 'group:bot' }))?.text).toContain('(1)')
  await ui.unmount()
})

test('hiding a PR takes it off the list and Unhide brings it back', async ($, on) => {
  await start($, engine(on))
  const url = 'https://github.com/getsentry/sentry/pull/202'

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: `row:${url}` })
  await ui.press({ key: `hide-week:${url}` })
  expect(await ui.find({ key: `row:${url}` })).toBeUndefined()
  expect((await ui.find({ key: 'toggle-hidden' }))?.text).toContain('Hidden (1)')
  await ui.press({ key: 'toggle-hidden' })
  await ui.press({ key: `unhide:${url}` })
  await ui.press({ key: 'toggle-hidden' })
  expect(await ui.find({ key: `row:${url}` })).toBeDefined()
  await ui.unmount()
})

test('a gh failure shows its error instead of an empty list', async ($, on) => {
  await start($, engine(on, { exitCode: 1, stdout: '', stderr: 'gh: not logged in\n' }))

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /not logged in/ }))?.text).toContain('gh: not logged in')
  await ui.unmount()
})
