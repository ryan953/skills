// Where a task sits on the board: under its Linear team and project, or, with no ticket,
// under the repo of its PR. A PR linked to a ticket follows the ticket.
export function taskGroup(task, items) {
  const members = task.items.map(k => items[k]).filter(Boolean);
  // The owner decides when it can; open items outrank closed ones, which may be stale links.
  const pick = type =>
    [items[task.owner], ...members.filter(i => i.open), ...members].find(i => i?.type === type);
  const ticket = pick('linear');
  if (ticket) return {kind: 'team', team: ticket.meta.teamName ?? ticket.meta.team, project: ticket.meta.project ?? null};
  const pr = pick('pr');
  if (pr) return {kind: 'repo', repo: pr.meta.repo};
  return {kind: 'other'};
}
