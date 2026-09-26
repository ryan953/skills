// PR state machine, from the author's point of view. It runs while a task is in_review.
// Loads as a plain <script> (sets window.PrMachine) or via require() in Node.
//
// The PR stores facts, and its status is derived from them. That way "CI fixed and
// feedback addressed" lands back on awaiting_review (or accepted) without anyone
// having to remember which status it was in before.
(function (root) {
  const statuses = {
    ci_failed: {label: 'CI failed', when: 'CI failed'},
    has_feedback: {label: 'Has feedback', when: 'unresolved comments'},
    accepted: {label: 'Accepted', when: 'marked accepted'},
    awaiting_review: {label: 'Awaiting review', when: 'otherwise'},
    merged: {label: 'Merged', final: true},
    closed: {label: 'Closed', final: true},
  };

  // First match wins. CI and feedback outrank accepted, so an accepted PR
  // that picks up a failure or a comment shows that instead.
  const priority = ['ci_failed', 'has_feedback', 'accepted', 'awaiting_review'];

  function create() {
    return {ci: 'pending', openComments: 0, accepted: false, merged: false, closed: false};
  }

  function status(pr) {
    if (pr.merged) return 'merged';
    if (pr.closed) return 'closed';
    if (pr.ci === 'failed') return 'ci_failed';
    if (pr.openComments > 0) return 'has_feedback';
    if (pr.accepted) return 'accepted';
    return 'awaiting_review';
  }

  // `resolves` names the status an author action is the fix for. CI results only
  // arrive while a run is pending, so a failed run is fixed by pushing new commits
  // (which start a new run), and feedback is fixed by replying to each comment.
  const events = {
    NEW_COMMITS: {
      label: 'Push new commits',
      actor: 'author',
      resolves: 'ci_failed',
      apply: pr => ({...pr, ci: 'pending'}),
    },
    CI_PASSED: {
      label: 'CI passes',
      actor: 'ci',
      guard: pr => pr.ci === 'pending',
      guardLabel: 'a CI run in progress',
      apply: pr => ({...pr, ci: 'passed'}),
    },
    CI_FAILED: {
      label: 'CI fails',
      actor: 'ci',
      guard: pr => pr.ci === 'pending',
      guardLabel: 'a CI run in progress',
      apply: pr => ({...pr, ci: 'failed'}),
    },
    COMMENT_ADDED: {label: 'Reviewer comments', actor: 'reviewer', apply: pr => ({...pr, openComments: pr.openComments + 1})},
    COMMENT_REPLIED: {
      label: 'Reply to a comment',
      actor: 'author',
      resolves: 'has_feedback',
      guard: pr => pr.openComments > 0,
      guardLabel: 'an unresolved comment',
      apply: pr => ({...pr, openComments: pr.openComments - 1}),
    },
    ACCEPTED: {
      label: 'Mark accepted',
      actor: 'reviewer',
      guard: pr => !pr.accepted,
      guardLabel: 'the PR not already accepted',
      apply: pr => ({...pr, accepted: true}),
    },
    MERGED: {
      label: 'Merge PR',
      actor: 'author',
      guard: pr => status(pr) === 'accepted',
      guardLabel: 'the PR to be accepted, with CI not failing and no unresolved comments',
      apply: pr => ({...pr, merged: true}),
    },
    // Closed without merging. The task ignores closed PRs.
    CLOSED: {label: 'Close PR', actor: 'author', apply: pr => ({...pr, closed: true})},
  };

  function check(pr, event) {
    const e = events[event];
    if (!e) return {ok: false, reason: `Unknown PR event ${event}`};
    if (pr.merged || pr.closed) return {ok: false, reason: `Event ${event} is not allowed on a ${status(pr)} PR`};
    if (e.guard && !e.guard(pr)) return {ok: false, reason: `Event ${event} needs ${e.guardLabel}`};
    return {ok: true};
  }

  function apply(pr, event) {
    const result = check(pr, event);
    if (!result.ok) throw new Error(result.reason);
    return events[event].apply(pr);
  }

  // For each open status, every event that can happen there and the statuses it can
  // lead to. Found by trying every event on every combination of facts, so it stays
  // true to status() and the guards. Used to draw the map.
  function outcomes() {
    const result = {};
    for (const ci of ['pending', 'passed', 'failed']) {
      for (const openComments of [0, 1, 2]) {
        for (const accepted of [false, true]) {
          const pr = {...create(), ci, openComments, accepted};
          const from = status(pr);
          result[from] ??= {};
          for (const event of Object.keys(events)) {
            if (!check(pr, event).ok) continue;
            const to = status(apply(pr, event));
            const seen = (result[from][event] ??= []);
            if (!seen.includes(to)) seen.push(to);
          }
        }
      }
    }
    const order = [...priority, 'merged', 'closed'];
    for (const byEvent of Object.values(result)) {
      for (const list of Object.values(byEvent)) list.sort((a, b) => order.indexOf(a) - order.indexOf(b));
    }
    return result;
  }

  const PrMachine = {statuses, priority, events, create, status, check, apply, outcomes};

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = PrMachine;
  } else {
    root.PrMachine = PrMachine;
  }
})(typeof window !== 'undefined' ? window : globalThis);
