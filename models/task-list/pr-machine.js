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
  };

  // First match wins. CI and feedback outrank accepted, so an accepted PR
  // that picks up a failure or a comment shows that instead.
  const priority = ['ci_failed', 'has_feedback', 'accepted', 'awaiting_review'];

  function create() {
    return {ci: 'pending', openComments: 0, accepted: false, merged: false};
  }

  function status(pr) {
    if (pr.merged) return 'merged';
    if (pr.ci === 'failed') return 'ci_failed';
    if (pr.openComments > 0) return 'has_feedback';
    if (pr.accepted) return 'accepted';
    return 'awaiting_review';
  }

  const events = {
    CI_PASSED: {label: 'CI passes', actor: 'ci', apply: pr => ({...pr, ci: 'passed'})},
    CI_FAILED: {label: 'CI fails', actor: 'ci', apply: pr => ({...pr, ci: 'failed'})},
    COMMENT_ADDED: {label: 'Reviewer comments', actor: 'reviewer', apply: pr => ({...pr, openComments: pr.openComments + 1})},
    COMMENT_ADDRESSED: {
      label: 'Address a comment',
      actor: 'author',
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
    MERGED: {label: 'Merge PR', actor: 'author', apply: pr => ({...pr, merged: true})},
  };

  function check(pr, event) {
    const e = events[event];
    if (!e) return {ok: false, reason: `Unknown PR event ${event}`};
    if (pr.merged) return {ok: false, reason: `Event ${event} is not allowed on a merged PR`};
    if (e.guard && !e.guard(pr)) return {ok: false, reason: `Event ${event} needs ${e.guardLabel}`};
    return {ok: true};
  }

  function apply(pr, event) {
    const result = check(pr, event);
    if (!result.ok) throw new Error(result.reason);
    return events[event].apply(pr);
  }

  const PrMachine = {statuses, priority, events, create, status, check, apply};

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = PrMachine;
  } else {
    root.PrMachine = PrMachine;
  }
})(typeof window !== 'undefined' ? window : globalThis);
