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
      description: 'A PR for the task is open. The PR runs its own machine (pr-machine.js) until it merges.',
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
  //
  // Being a parent is not a status. "Has incomplete subtasks" is derived from
  // childStates, and it is what holds a task back from moving to done.
  function hasIncompleteChildren(ctx = {}) {
    return (ctx.childStates ?? []).some(s => s !== 'done');
  }

  // Status changes. `from: null` means the task does not exist yet; ENTER creates it.
  // Actor `pr` means the change follows a pull request event, not a person editing the task.
  const transitions = [
    {event: 'ENTER', from: null, to: 'todo', actor: 'human', label: 'enter task', button: 'Save task'},
    {event: 'START', from: 'todo', to: 'in_progress', actor: 'human', label: 'read & start', button: 'Read & start'},
    {event: 'PR_CREATED', from: 'in_progress', to: 'in_review', actor: 'pr', label: 'PR created', button: 'Create PR'},
    {
      event: 'PR_MERGED',
      from: 'in_review',
      to: 'done',
      actor: 'pr',
      label: 'PR merged',
      button: 'Merge PR',
      guard: ctx => !hasIncompleteChildren(ctx),
      guardLabel: 'no incomplete subtasks',
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
  ];

  function find(state, event) {
    const t = transitions.find(t => t.from === state && t.event === event);
    if (t) return t;
    const a = actions.find(a => a.event === event && a.states.includes(state));
    return a ? {...a, from: state, to: state} : null;
  }

  // Everything a human can do to a task in this status: status changes and actions.
  function available(state) {
    return [
      ...transitions.filter(t => t.from === state),
      ...actions.filter(a => a.states.includes(state)).map(a => ({...a, from: state, to: state})),
    ];
  }

  function check(state, event, ctx = {}) {
    const match = find(state, event);
    if (!match) {
      return {ok: false, reason: `Event ${event} is not allowed from state ${state ?? '(none)'}`};
    }
    if (match.guard && !match.guard(ctx)) {
      return {ok: false, reason: `Event ${event} needs ${match.guardLabel}`, transition: match};
    }
    return {ok: true, transition: match};
  }

  function transition(state, event, ctx = {}) {
    const result = check(state, event, ctx);
    if (!result.ok) {
      throw new Error(result.reason);
    }
    return result.transition.to;
  }

  const TaskMachine = {states, transitions, actions, available, check, transition, hasIncompleteChildren};

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = TaskMachine;
  } else {
    root.TaskMachine = TaskMachine;
  }
})(typeof window !== 'undefined' ? window : globalThis);
