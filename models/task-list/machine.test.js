const test = require('node:test');
const assert = require('node:assert');
const {states, transition, available, check, settle, hasIncompleteChildren, readyForDone} = require('./machine.js');

test('happy path: enter, start, PR created, auto done once the PR merges', () => {
  let state = transition(null, 'ENTER');
  assert.equal(state, 'todo');
  state = transition(state, 'START');
  assert.equal(state, 'in_progress');
  state = transition(state, 'PR_CREATED');
  assert.equal(state, 'in_review');
  assert.equal(settle(state, {prStatuses: ['accepted']}), null);
  assert.equal(settle(state, {prStatuses: ['merged']}), 'AUTO_DONE');
  assert.equal(transition(state, 'AUTO_DONE', {prStatuses: ['merged']}), 'done');
});

test('the only statuses are todo, in_progress, in_review and done', () => {
  assert.deepEqual(Object.keys(states), ['todo', 'in_progress', 'in_review', 'done']);
});

test('done is final: no transitions and no actions', () => {
  assert.equal(states.done.final, true);
  assert.deepEqual(available('done'), []);
  assert.throws(() => transition('done', 'DECOMPOSE', {newSubtasks: 1}), /not allowed/);
});

test('cannot skip straight from todo to done', () => {
  assert.throws(() => transition('todo', 'COMPLETE'), /not allowed/);
  assert.throws(() => transition('todo', 'AUTO_DONE'), /not allowed/);
});

test('a PR cannot be created for a task nobody has started', () => {
  assert.throws(() => transition('todo', 'PR_CREATED'), /not allowed/);
});

test('cannot re-enter an existing task', () => {
  assert.throws(() => transition('todo', 'ENTER'), /not allowed/);
});

test('a task can link more PRs while in review, status unchanged', () => {
  assert.equal(transition('in_review', 'PR_CREATED'), 'in_review');
});

test('with several PRs, done waits for every one to merge', () => {
  assert.equal(settle('in_review', {prStatuses: ['merged', 'has_feedback']}), null);
  assert.equal(settle('in_review', {prStatuses: ['merged', 'merged']}), 'AUTO_DONE');
});

test('done waits for subtasks as well as PRs', () => {
  assert.equal(settle('in_review', {prStatuses: ['merged'], childStates: ['in_progress']}), null);
  assert.equal(settle('in_review', {prStatuses: ['merged'], childStates: ['done']}), 'AUTO_DONE');
});

test('settle never finishes a task that is not in review', () => {
  assert.equal(settle('in_progress', {childStates: ['done']}), null);
  assert.equal(settle('todo', {}), null);
});

test('a task with no PRs is marked done by hand once its subtasks are done', () => {
  assert.equal(check('in_progress', 'COMPLETE', {childStates: ['done', 'todo']}).ok, false);
  assert.equal(transition('in_progress', 'COMPLETE', {childStates: ['done', 'done']}), 'done');
});

test('readiness needs every PR merged and every subtask done', () => {
  assert.equal(readyForDone({}), true);
  assert.equal(readyForDone({prStatuses: ['merged'], childStates: ['done']}), true);
  assert.equal(readyForDone({prStatuses: ['accepted']}), false);
  assert.equal(readyForDone({childStates: ['in_review']}), false);
});

test('decomposing leaves status unchanged in todo, in_progress and in_review', () => {
  for (const s of ['todo', 'in_progress', 'in_review']) {
    assert.equal(transition(s, 'DECOMPOSE', {newSubtasks: 1}), s);
  }
});

test('decompose needs at least one new subtask', () => {
  assert.throws(() => transition('todo', 'DECOMPOSE', {newSubtasks: 0}), /at least one new subtask/);
});

test('incomplete subtasks are derived from child states', () => {
  assert.equal(hasIncompleteChildren({}), false);
  assert.equal(hasIncompleteChildren({childStates: ['done', 'in_progress']}), true);
});

test('a parent can be started and go into review while its subtasks are open', () => {
  assert.equal(transition('todo', 'START', {childStates: ['todo']}), 'in_progress');
  assert.equal(transition('in_progress', 'PR_CREATED', {childStates: ['todo']}), 'in_review');
});

test('closed PRs are ignored when deciding done', () => {
  assert.equal(readyForDone({prStatuses: ['merged', 'closed']}), true);
  assert.equal(settle('in_review', {prStatuses: ['closed', 'merged', 'merged']}), 'AUTO_DONE');
});

test('closing a PR while others are open leaves the task in review', () => {
  assert.equal(transition('in_review', 'PR_CLOSED', {prStatuses: ['closed', 'awaiting_review']}), 'in_review');
});

test('closing the last open PR, with another merged, sends the task back to in progress', () => {
  assert.equal(transition('in_review', 'PR_CLOSED', {prStatuses: ['merged', 'closed']}), 'in_progress');
});

test('closing the only PR sends the task back to todo', () => {
  assert.equal(transition('in_review', 'PR_CLOSED', {prStatuses: ['closed']}), 'todo');
  assert.equal(transition('in_review', 'PR_CLOSED', {prStatuses: ['closed', 'closed']}), 'todo');
});

test('a task sent back can open a new PR and go into review again', () => {
  assert.equal(transition('in_progress', 'PR_CREATED', {prStatuses: ['merged', 'closed']}), 'in_review');
});
