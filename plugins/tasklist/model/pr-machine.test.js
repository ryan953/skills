const test = require('node:test');
const assert = require('node:assert');
const {create, status, apply, check} = require('./pr-machine.js');

const run = (...events) => events.reduce(apply, create());

test('a new PR is awaiting review', () => {
  assert.equal(status(create()), 'awaiting_review');
});

test('CI running or passing keeps it awaiting review', () => {
  assert.equal(create().ci, 'pending');
  assert.equal(status(run('CI_PASSED')), 'awaiting_review');
});

test('CI results only arrive while a run is pending', () => {
  assert.throws(() => run('CI_FAILED', 'CI_PASSED'), /CI run in progress/);
  assert.throws(() => run('CI_PASSED', 'CI_FAILED'), /CI run in progress/);
});

test('pushing new commits resolves a CI failure and starts a new run', () => {
  const pr = run('CI_FAILED', 'NEW_COMMITS');
  assert.equal(pr.ci, 'pending');
  assert.equal(status(pr), 'awaiting_review');
  assert.equal(status(apply(pr, 'CI_FAILED')), 'ci_failed');
});

test('replying to every comment resolves feedback', () => {
  const pr = run('COMMENT_ADDED', 'COMMENT_ADDED', 'COMMENT_REPLIED');
  assert.equal(status(pr), 'has_feedback');
  assert.equal(status(apply(pr, 'COMMENT_REPLIED')), 'awaiting_review');
});

test('the fixes are named on the events', () => {
  const {events} = require('./pr-machine.js');
  assert.equal(events.NEW_COMMITS.resolves, 'ci_failed');
  assert.equal(events.COMMENT_REPLIED.resolves, 'has_feedback');
});

test('failing CI means ci_failed', () => {
  assert.equal(status(run('CI_FAILED')), 'ci_failed');
});

test('a reviewer comment means has_feedback', () => {
  assert.equal(status(run('COMMENT_ADDED')), 'has_feedback');
});

test('addressing CI and every comment returns to awaiting review', () => {
  const pr = run('CI_FAILED', 'COMMENT_ADDED', 'COMMENT_ADDED', 'NEW_COMMITS', 'CI_PASSED', 'COMMENT_REPLIED');
  assert.equal(status(pr), 'has_feedback');
  assert.equal(status(apply(pr, 'COMMENT_REPLIED')), 'awaiting_review');
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
  pr = apply(apply(apply(pr, 'NEW_COMMITS'), 'CI_PASSED'), 'COMMENT_ADDED');
  assert.equal(status(pr), 'has_feedback');
  assert.equal(status(apply(pr, 'COMMENT_REPLIED')), 'accepted');
});

test('cannot address a comment that does not exist', () => {
  assert.throws(() => run('COMMENT_REPLIED'), /unresolved comment/);
});

test('only an accepted PR can merge', () => {
  assert.throws(() => run('MERGED'), /accepted/);
  assert.throws(() => run('ACCEPTED', 'CI_FAILED', 'MERGED'), /accepted/);
  assert.throws(() => run('ACCEPTED', 'COMMENT_ADDED', 'MERGED'), /accepted/);
  assert.equal(status(run('ACCEPTED', 'MERGED')), 'merged');
});

test('merged is final', () => {
  const pr = run('ACCEPTED', 'MERGED');
  assert.equal(status(pr), 'merged');
  assert.equal(check(pr, 'COMMENT_ADDED').ok, false);
});

test('a PR can be closed from any open status, and closed is final', () => {
  for (const events of [[], ['CI_FAILED'], ['COMMENT_ADDED'], ['ACCEPTED']]) {
    const pr = run(...events, 'CLOSED');
    assert.equal(status(pr), 'closed');
    assert.equal(check(pr, 'MERGED').ok, false);
  }
});

test('a merged PR cannot be closed', () => {
  assert.throws(() => run('ACCEPTED', 'MERGED', 'CLOSED'), /merged PR/);
});

test('outcomes: merging is only possible from accepted', () => {
  const o = require('./pr-machine.js').outcomes();
  assert.deepEqual(o.accepted.MERGED, ['merged']);
  for (const s of ['awaiting_review', 'ci_failed', 'has_feedback']) assert.equal(o[s].MERGED, undefined);
});

test('outcomes: new commits fix CI and can land on any lower status', () => {
  const o = require('./pr-machine.js').outcomes();
  assert.deepEqual(o.ci_failed.NEW_COMMITS, ['has_feedback', 'accepted', 'awaiting_review']);
  assert.equal(o.ci_failed.CI_PASSED, undefined);
});

test('outcomes: replying fixes feedback', () => {
  const o = require('./pr-machine.js').outcomes();
  assert.deepEqual(o.has_feedback.COMMENT_REPLIED, ['has_feedback', 'accepted', 'awaiting_review']);
});

test('outcomes: a new comment on an accepted PR means has_feedback', () => {
  const o = require('./pr-machine.js').outcomes();
  assert.deepEqual(o.accepted.COMMENT_ADDED, ['has_feedback']);
  assert.deepEqual(o.ci_failed.COMMENT_ADDED, ['ci_failed']);
});

test('every kind names an actor for every event', () => {
  const {kinds, events} = require('./pr-machine.js');
  for (const k of Object.values(kinds)) {
    assert.deepEqual(Object.keys(k.actors).sort(), Object.keys(events).sort());
  }
});

test('my PRs: I push fixes, address feedback and merge', () => {
  const {myEvents} = require('./pr-machine.js');
  assert.deepEqual(myEvents('mine').sort(), ['CLOSED', 'COMMENT_REPLIED', 'MERGED', 'NEW_COMMITS']);
});

test('bot PRs: I push fixes and merge, but the bot answers feedback', () => {
  const {myEvents, actor} = require('./pr-machine.js');
  assert.ok(myEvents('bot').includes('NEW_COMMITS'));
  assert.ok(myEvents('bot').includes('MERGED'));
  assert.equal(actor('bot', 'COMMENT_REPLIED'), 'bot');
});

test("others' PRs: I comment and accept; the author fixes and merges", () => {
  const {myEvents, actor} = require('./pr-machine.js');
  assert.deepEqual(myEvents('other').sort(), ['ACCEPTED', 'COMMENT_ADDED']);
  assert.equal(actor('other', 'MERGED'), 'author');
  assert.equal(actor('other', 'NEW_COMMITS'), 'author');
});

test('my actions get kind-specific names', () => {
  const {label} = require('./pr-machine.js');
  assert.equal(label('mine', 'NEW_COMMITS'), 'Self-review & push fixes');
  assert.equal(label('other', 'COMMENT_ADDED'), 'Review & comment');
  assert.equal(label('other', 'MERGED'), 'Merge PR');
});

test('my PRs come from tasks, or are detected when they did not', () => {
  const {open, status} = require('./pr-machine.js');
  assert.equal(open('mine', 'task').origin, 'task');
  assert.equal(status(open('mine', 'detected').facts), 'awaiting_review');
});

test('bot and other people\'s PRs are only ever detected', () => {
  const {open} = require('./pr-machine.js');
  assert.equal(open('bot', 'detected').kind, 'bot');
  assert.equal(open('other', 'detected').kind, 'other');
  assert.throws(() => open('bot', 'task'), /not created from a task/);
  assert.throws(() => open('other', 'task'), /not created from a task/);
});
