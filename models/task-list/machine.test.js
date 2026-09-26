const test = require('node:test');
const assert = require('node:assert');
const {states, transition, available, check, hasIncompleteChildren} = require('./machine.js');

test('happy path: enter, start, PR created, PR merged', () => {
  let state = transition(null, 'ENTER');
  assert.equal(state, 'todo');
  state = transition(state, 'START');
  assert.equal(state, 'in_progress');
  state = transition(state, 'PR_CREATED');
  assert.equal(state, 'in_review');
  state = transition(state, 'PR_MERGED');
  assert.equal(state, 'done');
});

test('the only statuses are todo, in_progress, in_review and done', () => {
  assert.deepEqual(Object.keys(states), ['todo', 'in_progress', 'in_review', 'done']);
});

test('in-progress work cannot skip review', () => {
  assert.throws(() => transition('in_progress', 'PR_MERGED'), /not allowed/);
});

test('a PR cannot be created for a task nobody has started', () => {
  assert.throws(() => transition('todo', 'PR_CREATED'), /not allowed/);
});

test('done is final: no transitions and no actions', () => {
  assert.equal(states.done.final, true);
  assert.deepEqual(available('done'), []);
  assert.throws(() => transition('done', 'DECOMPOSE', {newSubtasks: 1}), /not allowed/);
});

test('cannot skip straight from todo to done', () => {
  assert.throws(() => transition('todo', 'PR_MERGED'), /not allowed/);
});

test('cannot re-enter an existing task', () => {
  assert.throws(() => transition('todo', 'ENTER'), /not allowed/);
});

test('decomposing a todo task leaves it todo', () => {
  assert.equal(transition('todo', 'DECOMPOSE', {newSubtasks: 2}), 'todo');
});

test('decomposing an in-progress task leaves it in progress', () => {
  assert.equal(transition('in_progress', 'DECOMPOSE', {newSubtasks: 1}), 'in_progress');
});

test('decomposing an in-review task leaves it in review', () => {
  assert.equal(transition('in_review', 'DECOMPOSE', {newSubtasks: 1}), 'in_review');
});

test('decompose can repeat to add more subtasks', () => {
  assert.equal(transition('todo', 'DECOMPOSE', {newSubtasks: 1, childStates: ['todo', 'done']}), 'todo');
});

test('decompose needs at least one new subtask', () => {
  assert.throws(() => transition('todo', 'DECOMPOSE', {newSubtasks: 0}), /at least one new subtask/);
});

test('incomplete subtasks are derived from child states', () => {
  assert.equal(hasIncompleteChildren({}), false);
  assert.equal(hasIncompleteChildren({childStates: ['done', 'done']}), false);
  assert.equal(hasIncompleteChildren({childStates: ['done', 'in_progress']}), true);
});

test('a parent can be started while its subtasks are open', () => {
  assert.equal(transition('todo', 'START', {childStates: ['todo']}), 'in_progress');
});

test('a parent can go into review while its subtasks are open', () => {
  assert.equal(transition('in_progress', 'PR_CREATED', {childStates: ['todo']}), 'in_review');
});

test('a parent cannot move to done while any subtask is incomplete', () => {
  assert.equal(check('in_review', 'PR_MERGED', {childStates: ['done', 'in_review']}).ok, false);
  assert.equal(transition('in_review', 'PR_MERGED', {childStates: ['done', 'done']}), 'done');
});
