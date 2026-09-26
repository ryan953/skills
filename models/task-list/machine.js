// Task list state machine: the single definition the diagram, simulator and tests read.
// Loads as a plain <script> (sets window.TaskMachine) or via require() in Node.
(function (root) {
  const states = {
    todo: {
      label: 'Todo',
      description: 'A human entered the task and it was stored. Nobody has started it yet.',
    },
    in_progress: {
      label: 'In progress',
      description: 'A human read the task and is working on it.',
    },
    in_review: {
      label: 'In review',
      description: 'At least one linked PR is open. Each PR runs its own machine (pr-machine.js).',
    },
    done: {
      label: 'Done',
      description: 'The work is finished. No further transitions or actions.',
      final: true,
    },
  };

  // Guards read a context the caller supplies:
  //   newSubtasks  - how many subtasks this event creates
  //   childStates  - current states of the task's direct subtasks
  //   prStatuses   - current statuses of the task's linked PRs (see pr-machine.js)
  //
  // Being a parent, or having PRs, is not a status. Both are derived from the
  // context, and together they decide whether a task can be done.
  function hasIncompleteChildren(ctx = {}) {
    return (ctx.childStates ?? []).some(s => s !== 'done');
  }

  // Closed PRs are ignored: they neither count as finished work nor hold a task back.
  function hasUnmergedPrs(ctx = {}) {
    return (ctx.prStatuses ?? []).some(s => s !== 'merged' && s !== 'closed');
  }

  const hasOpenPrs = hasUnmergedPrs;
  const hasMergedPrs = (ctx = {}) => (ctx.prStatuses ?? []).includes('merged');

  // A task can be done only when every linked PR is merged and every subtask is done.
  function readyForDone(ctx = {}) {
    return !hasIncompleteChildren(ctx) && !hasUnmergedPrs(ctx);
  }

  // Status changes. `from: null` means the task does not exist yet; ENTER creates it.
  // Actor `pr` means the change follows a pull request event, not a person editing the task.
  // Actor `auto` means nobody fires it: callers ask settle() after anything that could
  // make it true (a PR merging, a subtask finishing), and apply what it returns.
  const transitions = [
    {event: 'ENTER', from: null, to: 'todo', actor: 'human', label: 'enter task', button: 'Save task'},
    {event: 'START', from: 'todo', to: 'in_progress', actor: 'human', label: 'read & start', button: 'Read & start'},
    {event: 'PR_CREATED', from: 'in_progress', to: 'in_review', actor: 'pr', label: 'PR created', button: 'Create PR'},
    {
      event: 'AUTO_DONE',
      from: 'in_review',
      to: 'done',
      actor: 'auto',
      label: 'all PRs merged',
      guard: readyForDone,
      guardLabel: 'all linked PRs merged and no incomplete subtasks',
    },
    // Closing a PR. prStatuses already includes the closed one as 'closed'.
    // With other PRs still open it is an action (below); otherwise the task steps back.
    {
      event: 'PR_CLOSED',
      from: 'in_review',
      to: 'in_progress',
      actor: 'pr',
      label: 'last open PR closed',
      guard: ctx => !hasOpenPrs(ctx) && hasMergedPrs(ctx),
      guardLabel: 'no open PRs left, and at least one merged',
    },
    {
      event: 'PR_CLOSED',
      from: 'in_review',
      to: 'todo',
      actor: 'pr',
      label: 'only PR closed',
      guard: ctx => !hasOpenPrs(ctx) && !hasMergedPrs(ctx),
      guardLabel: 'no other PRs, open or merged',
    },
    {
      // For tasks with no PRs of their own, such as a parent that only groups subtasks.
      event: 'COMPLETE',
      from: 'in_progress',
      to: 'done',
      actor: 'human',
      label: 'mark done',
      button: 'Mark done',
      guard: readyForDone,
      guardLabel: 'all linked PRs merged and no incomplete subtasks',
    },
  ];

  // Actions taken against a task that leave its status unchanged.
  // DECOMPOSE gives the task subtasks, making it a parent. Each subtask is an
  // ordinary task, created with ENTER, running this same machine.
  const actions = [
    {
      event: 'DECOMPOSE',
      states: ['todo', 'in_progress', 'in_review'],
      actor: 'human',
      label: 'decompose',
      button: 'Decompose',
      guard: ctx => (ctx.newSubtasks ?? 0) > 0,
      guardLabel: 'at least one new subtask',
    },
    {
      // Linking another PR while already in review. The first PR is the PR_CREATED transition.
      event: 'PR_CREATED',
      states: ['in_review'],
      actor: 'pr',
      label: 'another PR created',
      button: 'Create another PR',
    },
    {
      event: 'PR_CLOSED',
      states: ['in_review'],
      actor: 'pr',
      label: 'PR closed, others still open',
      guard: hasOpenPrs,
      guardLabel: 'another PR still open',
    },
  ];

  // All definitions for this event in this state. Some events (PR_CLOSED) have
  // several, told apart by their guards.
  function candidates(state, event) {
    return [
      ...transitions.filter(t => t.from === state && t.event === event),
      ...actions.filter(a => a.event === event && a.states.includes(state)).map(a => ({...a, from: state, to: state})),
    ];
  }

  // Everything a human can do to a task in this status: status changes and actions.
  function available(state) {
    return [
      ...transitions.filter(t => t.from === state),
      ...actions.filter(a => a.states.includes(state)).map(a => ({...a, from: state, to: state})),
    ];
  }

  function check(state, event, ctx = {}) {
    const all = candidates(state, event);
    if (!all.length) {
      return {ok: false, reason: `Event ${event} is not allowed from state ${state ?? '(none)'}`};
    }
    const match = all.find(t => !t.guard || t.guard(ctx));
    if (!match) {
      return {ok: false, reason: `Event ${event} needs ${all[0].guardLabel}`, transition: all[0]};
    }
    return {ok: true, transition: match};
  }

  // The automatic transition that applies right now, if any.
  function settle(state, ctx = {}) {
    const auto = transitions.find(t => t.actor === 'auto' && t.from === state && t.guard(ctx));
    return auto ? auto.event : null;
  }

  function transition(state, event, ctx = {}) {
    const result = check(state, event, ctx);
    if (!result.ok) {
      throw new Error(result.reason);
    }
    return result.transition.to;
  }

  const TaskMachine = {states, transitions, actions, available, check, transition, settle, hasIncompleteChildren, hasUnmergedPrs, hasOpenPrs, readyForDone};

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = TaskMachine;
  } else {
    root.TaskMachine = TaskMachine;
  }
})(typeof window !== 'undefined' ? window : globalThis);
