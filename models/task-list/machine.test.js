const test = require('node:test');
const assert = require('node:assert');
const {states, transition, available, check} = require('./machine.js');

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

test('decompose a saved task into subtasks', () => {
  assert.equal(transition('saved', 'DECOMPOSE', {newSubtasks: 2}), 'decomposed');
});

test('decompose needs at least one subtask', () => {
  assert.throws(() => transition('saved', 'DECOMPOSE', {newSubtasks: 0}), /at least one subtask/);
});

test('cannot decompose once work has started', () => {
  assert.throws(() => transition('in_progress', 'DECOMPOSE', {newSubtasks: 1}), /not allowed/);
});

test('can add more subtasks while decomposed', () => {
  assert.equal(transition('decomposed', 'ADD_SUBTASK', {newSubtasks: 1}), 'decomposed');
});

test('decomposed task completes only when every subtask is complete', () => {
  assert.equal(check('decomposed', 'COMPLETE', {childStates: ['complete', 'in_progress']}).ok, false);
  assert.equal(check('decomposed', 'COMPLETE', {childStates: ['complete', 'decomposed']}).ok, false);
  assert.equal(transition('decomposed', 'COMPLETE', {childStates: ['complete', 'complete']}), 'complete');
});

test('decomposed task cannot be started directly', () => {
  assert.throws(() => transition('decomposed', 'START'), /not allowed/);
});
