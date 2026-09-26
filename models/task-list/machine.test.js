const test = require('node:test');
const assert = require('node:assert');
const {states, transition, available, check, hasIncompleteChildren} = require('./machine.js');

test('happy path: enter, start, complete', () => {
  let state = transition(null, 'ENTER');
  assert.equal(state, 'saved');
  state = transition(state, 'START');
  assert.equal(state, 'in_progress');
  state = transition(state, 'COMPLETE');
  assert.equal(state, 'complete');
});

test('complete is final', () => {
  assert.equal(states.complete.final, true);
  assert.deepEqual(available('complete'), []);
});

test('cannot skip straight from saved to complete', () => {
  assert.throws(() => transition('saved', 'COMPLETE'), /not allowed/);
});

test('cannot re-enter an existing task', () => {
  assert.throws(() => transition('saved', 'ENTER'), /not allowed/);
});

test('there is no decomposed state', () => {
  assert.deepEqual(Object.keys(states), ['saved', 'in_progress', 'complete']);
});

test('decompose is an action: the task stays saved', () => {
  assert.equal(transition('saved', 'DECOMPOSE', {newSubtasks: 2}), 'saved');
});

test('decompose can repeat to add more subtasks', () => {
  assert.equal(transition('saved', 'DECOMPOSE', {newSubtasks: 1, childStates: ['saved', 'complete']}), 'saved');
});

test('decompose needs at least one new subtask', () => {
  assert.throws(() => transition('saved', 'DECOMPOSE', {newSubtasks: 0}), /at least one new subtask/);
});

test('cannot decompose once work has started', () => {
  assert.throws(() => transition('in_progress', 'DECOMPOSE', {newSubtasks: 1}), /not allowed/);
});

test('incomplete subtasks are derived from child states', () => {
  assert.equal(hasIncompleteChildren({}), false);
  assert.equal(hasIncompleteChildren({childStates: ['complete', 'complete']}), false);
  assert.equal(hasIncompleteChildren({childStates: ['complete', 'in_progress']}), true);
});

test('a task with incomplete subtasks cannot be started', () => {
  assert.equal(check('saved', 'START', {childStates: ['complete', 'saved']}).ok, false);
  assert.equal(transition('saved', 'START', {childStates: ['complete', 'complete']}), 'in_progress');
});
