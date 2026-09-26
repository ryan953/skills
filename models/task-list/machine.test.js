const test = require('node:test');
const assert = require('node:assert');
const {states, transition, available, check, hasIncompleteChildren} = require('./machine.js');

test('happy path: enter, start, mark done', () => {
  let state = transition(null, 'ENTER');
  assert.equal(state, 'todo');
  state = transition(state, 'START');
  assert.equal(state, 'in_progress');
  state = transition(state, 'COMPLETE');
  assert.equal(state, 'done');
});

test('the only statuses are todo, in_progress and done', () => {
  assert.deepEqual(Object.keys(states), ['todo', 'in_progress', 'done']);
});

test('done is final: no transitions and no actions', () => {
  assert.equal(states.done.final, true);
  assert.deepEqual(available('done'), []);
  assert.throws(() => transition('done', 'DECOMPOSE', {newSubtasks: 1}), /not allowed/);
});

test('cannot skip straight from todo to done', () => {
  assert.throws(() => transition('todo', 'COMPLETE'), /not allowed/);
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

test('a parent cannot be marked done while any subtask is incomplete', () => {
  assert.equal(check('in_progress', 'COMPLETE', {childStates: ['done', 'todo']}).ok, false);
  assert.equal(transition('in_progress', 'COMPLETE', {childStates: ['done', 'done']}), 'done');
});
