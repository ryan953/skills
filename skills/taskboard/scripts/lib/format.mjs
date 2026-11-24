// One line of PR review detail, shared by the report and the mod's pane.
export function prDetailText(d) {
  if (!d) return null;
  const parts = [`+${d.additions} −${d.deletions}`, `${d.files} ${d.files === 1 ? 'file' : 'files'}`];
  const {passed, failed, pending} = d.checks;
  if (passed + failed + pending) parts.push([`✓${passed}`, failed && `✗${failed}`, pending && `◌${pending}`].filter(Boolean).join(' '));
  if (d.unresolved) parts.push(`${d.unresolved} unresolved`);
  if (d.warden) {
    parts.push(
      d.warden.running ? 'warden running' : d.warden.open ? `warden: ${d.warden.open} open of ${d.warden.found}` : 'warden: no problems'
    );
  }
  if (d.minorBots) parts.push(`${d.minorBots} bot ${d.minorBots === 1 ? 'note' : 'notes'}`);
  if (d.draftComments) parts.push(`your draft review: ${d.draftComments}`);
  return parts.join(' · ');
}
