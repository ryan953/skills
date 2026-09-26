const test = require('node:test');
const assert = require('node:assert');
const {create, status, apply, check} = require('./pr-machine.js');

const run = (...events) => events.reduce(apply, create());

test('a new PR is awaiting review', () => {
  assert.equal(status(create()), 'awaiting_review');
});

test('CI running or passing keeps it awaiting review', () => {
  assert.equal(status(run('CI_PASSED')), 'awaiting_review');
});

test('failing CI means ci_failed', () => {
  assert.equal(status(run('CI_FAILED')), 'ci_failed');
});

test('a reviewer comment means has_feedback', () => {
  assert.equal(status(run('COMMENT_ADDED')), 'has_feedback');
});

test('addressing CI and every comment returns to awaiting review', () => {
  const pr = run('CI_FAILED', 'COMMENT_ADDED', 'COMMENT_ADDED', 'CI_PASSED', 'COMMENT_ADDRESSED');
  assert.equal(status(pr), 'has_feedback');
  assert.equal(status(apply(pr, 'COMMENT_ADDRESSED')), 'awaiting_review');
});

test('CI failure outranks feedback', () => {
  assert.equal(status(run('COMMENT_ADDED', 'CI_FAILED')), 'ci_failed');
});

test('accepted replaces awaiting review', () => {
  assert.equal(status(run('CI_PASSED', 'ACCEPTED')), 'accepted');
});

test('CI failure and feedback outrank accepted, and accepted returns once they clear', () => {
  let pr = run('ACCEPTED', 'CI_FAILED');
  assert.equal(status(pr), 'ci_failed');
  pr = apply(apply(pr, 'CI_PASSED'), 'COMMENT_ADDED');
  assert.equal(status(pr), 'has_feedback');
  assert.equal(status(apply(pr, 'COMMENT_ADDRESSED')), 'accepted');
});

test('cannot address a comment that does not exist', () => {
  assert.throws(() => run('COMMENT_ADDRESSED'), /unresolved comment/);
});

test('merged is final', () => {
  const pr = run('ACCEPTED', 'MERGED');
  assert.equal(status(pr), 'merged');
  assert.equal(check(pr, 'COMMENT_ADDED').ok, false);
});
