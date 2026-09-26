// Task list state machine: the single definition the diagram, simulator and tests read.
// Loads as a plain <script> (sets window.TaskMachine) or via require() in Node.
(function (root) {
  const states = {
    saved: {
      label: 'Saved',
      description: 'A human entered the task and it was stored. Nobody has picked it up yet.',
    },
    in_progress: {
      label: 'In progress',
      description: 'A human read the task and is working on it.',
    },
    decomposed: {
      label: 'Decomposed',
      description: 'The task was split into subtasks. It waits here until every subtask is complete.',
    },
    complete: {
      label: 'Complete',
      description: 'The work is done. No further transitions.',
      final: true,
    },
  };

  // `from: null` means the task does not exist yet; ENTER is how it comes into being.
  // Subtasks are ordinary tasks: each one is created with ENTER and runs this same machine.
  // Guards read a context the caller supplies:
  //   newSubtasks  - how many subtasks this event creates
  //   childStates  - current states of the task's direct subtasks
  const transitions = [
    {event: 'ENTER', from: null, to: 'saved', actor: 'human', label: 'enter task'},
    {event: 'START', from: 'saved', to: 'in_progress', actor: 'human', label: 'read & start'},
    {event: 'COMPLETE', from: 'in_progress', to: 'complete', actor: 'human', label: 'mark complete'},
    {
      event: 'DECOMPOSE',
      from: 'saved',
      to: 'decomposed',
      actor: 'human',
      label: 'decompose',
      guard: ctx => (ctx.newSubtasks ?? 0) > 0,
      guardLabel: 'at least one subtask',
    },
    {
      event: 'ADD_SUBTASK',
      from: 'decomposed',
      to: 'decomposed',
      actor: 'human',
      label: 'add subtask',
      guard: ctx => (ctx.newSubtasks ?? 0) > 0,
      guardLabel: 'at least one subtask',
    },
    {
      event: 'COMPLETE',
      from: 'decomposed',
      to: 'complete',
      actor: 'human',
      label: 'mark complete',
      guard: ctx => (ctx.childStates ?? []).length > 0 && ctx.childStates.every(s => s === 'complete'),
      guardLabel: 'all subtasks complete',
    },
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

  const TaskMachine = {states, transitions, available, check, transition};

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = TaskMachine;
  } else {
    root.TaskMachine = TaskMachine;
  }
})(typeof window !== 'undefined' ? window : globalThis);
