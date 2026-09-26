// Task list state machine: the single definition the diagram, simulator and tests read.
// Loads as a plain <script> (sets window.TaskMachine) or via require() in Node.
(function (root) {
  const states = {
    saved: {
      label: 'Saved',
      description: 'A human entered the task and it was stored. Nobody has started it yet.',
    },
    in_progress: {
      label: 'In progress',
      description: 'A human read the task and is working on it.',
    },
    complete: {
      label: 'Complete',
      description: 'The work is done. No further transitions.',
      final: true,
    },
  };

  // Guards read a context the caller supplies:
  //   newSubtasks  - how many subtasks this event creates
  //   childStates  - current states of the task's direct subtasks
  //
  // "Has incomplete subtasks" is not a state. It is derived from childStates,
  // and it is what holds a saved task back from being started.
  function hasIncompleteChildren(ctx = {}) {
    return (ctx.childStates ?? []).some(s => s !== 'complete');
  }

  // `from: null` means the task does not exist yet; ENTER is how it comes into being.
  // DECOMPOSE is an action, not a state change: the task stays saved and gains subtasks.
  // Each subtask is an ordinary task, created with ENTER, running this same machine.
  const transitions = [
    {event: 'ENTER', from: null, to: 'saved', actor: 'human', label: 'enter task'},
    {
      event: 'DECOMPOSE',
      from: 'saved',
      to: 'saved',
      actor: 'human',
      label: 'decompose',
      guard: ctx => (ctx.newSubtasks ?? 0) > 0,
      guardLabel: 'at least one new subtask',
    },
    {
      event: 'START',
      from: 'saved',
      to: 'in_progress',
      actor: 'human',
      label: 'read & start',
      guard: ctx => !hasIncompleteChildren(ctx),
      guardLabel: 'no incomplete subtasks',
    },
    {event: 'COMPLETE', from: 'in_progress', to: 'complete', actor: 'human', label: 'mark complete'},
  ];

  function available(state) {
    return transitions.filter(t => t.from === state);
  }

  function check(state, event, ctx = {}) {
    const match = transitions.find(t => t.from === state && t.event === event);
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

  const TaskMachine = {states, transitions, available, check, transition, hasIncompleteChildren};

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = TaskMachine;
  } else {
    root.TaskMachine = TaskMachine;
  }
})(typeof window !== 'undefined' ? window : globalThis);
