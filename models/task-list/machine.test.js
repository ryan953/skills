const test = require('node:test');
const assert = require('node:assert');
const {states, transition, available} = require('./machine.js');

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
