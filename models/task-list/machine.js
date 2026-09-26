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
    complete: {
      label: 'Complete',
      description: 'The work is done. No further transitions.',
      final: true,
    },
  };

  // `from: null` means the task does not exist yet; ENTER is how it comes into being.
  const transitions = [
    {event: 'ENTER', from: null, to: 'saved', actor: 'human', label: 'enter task'},
    {event: 'START', from: 'saved', to: 'in_progress', actor: 'human', label: 'read & start'},
    {event: 'COMPLETE', from: 'in_progress', to: 'complete', actor: 'human', label: 'mark complete'},
  ];

  function available(state) {
    return transitions.filter(t => t.from === state);
  }

  function transition(state, event) {
    const match = transitions.find(t => t.from === state && t.event === event);
    if (!match) {
      throw new Error(`Event ${event} is not allowed from state ${state ?? '(none)'}`);
    }
    return match.to;
  }

  const TaskMachine = {states, transitions, available, transition};

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = TaskMachine;
  } else {
    root.TaskMachine = TaskMachine;
  }
})(typeof window !== 'undefined' ? window : globalThis);
