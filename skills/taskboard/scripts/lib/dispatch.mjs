// Decide where a task's next step goes (an existing session, its jr conversation, or a new
// session) and write the message or brief for it. The manager makes the tool call.

import {existsSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';

import {DEFAULT_REPO} from './refs.mjs';

// Stages where the next move is the user's, so nothing is sent to a worker.
const USER_STAGES = {
  'needs-you': 'a conversation or PR waits for your answer',
  merge: 'the PR is approved and green; merging is your call',
  done: 'the task is finished',
};

const BRIEFS = ['full', 'review', 'validate'];

const RULES = [
  'Do not merge a PR. Stop when it is ready to merge and say so.',
  'Ask before you post anything others see: PR reviews or comments, Linear comments or state changes, Slack messages.',
  'Commit only on your own branch. Do not push to a branch you did not create, except the PR branch of this task.',
  'When you stop, give one line of status: what is done, what is left, and what you need from me.',
];

// The manager checks that each question has an answer, not whether the answer is right,
// so a worker that skips one is sent back for it.
const CLOSE_OUT = [
  'Implementation: is a code change needed, or is this done, not a bug, or out of scope?',
  'Review: is more review needed (the agent review, bot threads, a deep-pr-review pass)?',
  'Tests: are the tests enough for this change? Which ones did you add or run?',
  'Skills: which of my skills apply here (for example commit, pr-writer, iterate-pr, deep-pr-review, verify-sentry, agent-browser, frontend-conventions), and did you use them?',
  'Sign-off: does this need my review, or a review request to the team?',
  'Next step: what is it, and who owns it: you, me or the team?',
];
const CLOSE_OUT_HEAD = 'Close-out: end each report with these answers, yes or no and one line each:';

const prLabel = p => (p.meta.repo === DEFAULT_REPO ? `#${p.meta.number}` : p.key);

function partsOf(members) {
  const of = t => members.filter(i => i.type === t);
  return {
    linear: of('linear'),
    prs: of('pr'),
    openPrs: of('pr').filter(p => p.open),
    ourPrs: of('pr').filter(p => p.open && p.roles.some(r => r === 'author' || r === 'bot')),
    jr: of('jr').filter(i => i.open),
    claude: of('claude').filter(i => i.open),
  };
}

const list = xs => xs.join(', ');
const tickets = p => list(p.linear.filter(l => l.open).map(l => l.key)) || list(p.linear.map(l => l.key));

// The one step that moves the task forward from its stage.
function stepFor(stage, brief, p) {
  const prs = list(p.openPrs.map(prLabel));
  if (brief === 'review' || stage === 'review') {
    return `Review ${prs} with the deep-pr-review skill (or code-review when deep-pr-review is not installed). Draft the review and show it to me. Ask before you post it.`;
  }
  if (stage === 'validate') {
    const then =
      brief === 'validate'
        ? 'Then stop.'
        : 'If it reproduces and I agree, go on to the fix: open a draft PR with `Fixes <ticket>` in its body, then iterate on it with the iterate-pr skill.';
    return `Validate ${tickets(p)}: reproduce it on a local devserver (use the verify-sentry skill when it covers the area). Report whether it reproduces, with screenshots. ${then}`;
  }
  if (stage === 'fix') {
    return `Fix ${tickets(p)}. Open a draft PR with \`Fixes <ticket>\` in its body, then iterate on it with the iterate-pr skill until CI is green and review comments are handled.`;
  }
  if (stage === 'iterate') {
    return `Iterate on ${list(p.ourPrs.map(prLabel))} with the iterate-pr skill: fix CI failures and handle review comments.`;
  }
  if (stage === 'verify') {
    return `${list(p.prs.filter(x => x.status === 'merged').map(prLabel))} merged. Check that ${tickets(p)} is fixed (use the verify-sentry skill when it covers the area). Tell me whether the ticket can close.`;
  }
  if (stage === 'follow-up') {
    return 'Finish what you said was left for this task. When it is done, say `NOTHING LEFT`.';
  }
  return 'Continue this task from where it stopped and give me its status.';
}

function itemLine(i) {
  const what = i.type === 'pr' ? `PR ${prLabel(i)} (${i.status})` : i.type === 'linear' ? `${i.key} (${i.status})` : i.type === 'jr' ? 'jr conversation' : 'Claude session';
  return `- ${what}: ${i.title}${i.url ? ` <${i.url}>` : ''}`;
}

function repoOf(p) {
  return p.openPrs[0]?.meta.repo ?? p.prs[0]?.meta.repo ?? DEFAULT_REPO;
}

// Local checkouts follow ~/code/<repo name>; when that is missing the manager picks the folder.
function cwdOf(repo) {
  const dir = join(homedir(), 'code', repo.split('/')[1]);
  return existsSync(dir) ? dir : null;
}

function sessionTitle(task, brief, p) {
  const head = brief === 'review' ? `Review ${list(p.openPrs.map(prLabel))}` : task.id;
  const room = 58 - head.length;
  const rest = task.title.length > room ? `${task.title.slice(0, room - 1)}…` : task.title;
  return `${head}: ${rest}`;
}

const newest = xs => [...xs].sort((a, b) => (b.updatedAt ?? '').localeCompare(a.updatedAt ?? ''))[0] ?? null;

// The owner wins; then a session, which has the repo and the history; then jr.
function pickReuse(task, p) {
  const owner = [...p.claude, ...p.jr].find(i => i.key === task.owner);
  return owner ?? newest(p.claude) ?? newest(p.jr.filter(j => j.meta.active)) ?? newest(p.jr);
}

export function dispatch(task, members, {brief, route, step} = {}) {
  if (brief && !BRIEFS.includes(brief)) throw new Error(`--brief must be one of ${BRIEFS.join(', ')}`);
  const p = partsOf(members);
  brief ??= task.kind === 'review' || task.stage === 'review' ? 'review' : 'full';
  const base = {task: task.id, stage: task.stage, brief};

  if (!route && !step && USER_STAGES[task.stage]) {
    return {...base, route: 'user', reason: USER_STAGES[task.stage]};
  }
  if (task.kind === 'adhoc' && !step && !route) {
    return {...base, route: 'user', reason: 'an adhoc task has no standard next step; pass --step "<text>"'};
  }

  const text = step ?? stepFor(task.stage, brief, p);
  // A follow-up goes back to the conversation that named it, which knows what it meant.
  const named = task.actions.find(a => a.type === 'follow-up');
  const reuse = members.find(i => i.key === named?.item) ?? pickReuse(task, p);
  const chosen = route ?? (reuse ? (reuse.type === 'claude' ? 'session' : 'jr') : 'new');

  if (chosen === 'session' || chosen === 'jr') {
    const type = chosen === 'session' ? 'claude' : 'jr';
    const target = reuse?.type === type ? reuse : newest(type === 'claude' ? p.claude : p.jr);
    if (!target) throw new Error(`Task ${task.id} has no live ${type} item to reuse.`);
    return {
      ...base,
      route: chosen,
      target: {key: target.key, title: target.title, url: target.url, running: Boolean(target.meta.running)},
      message: [text, '', ...RULES, '', CLOSE_OUT_HEAD, ...CLOSE_OUT.map(q => `- ${q}`)].join('\n'),
      reason: target.key === task.owner ? 'the task owner' : `the newest live ${type === 'claude' ? 'session' : 'jr conversation'} on the task`,
    };
  }

  const repo = repoOf(p);
  const tracked = members.filter(i => i.type === 'linear' || i.type === 'pr');
  const chain =
    brief === 'full'
      ? 'This is a full cycle: validate the ticket, fix it, open a draft PR, iterate until it is ready to merge. Start at the step below, which matches where the task is now.'
      : brief === 'review'
        ? 'This task is only a review. Do not change the code.'
        : 'This task is only validation. Do not write a fix.';
  return {
    ...base,
    route: 'new',
    title: sessionTitle(task, brief, p),
    repo,
    cwd: cwdOf(repo),
    prompt: [`Task ${task.id}: ${task.title}`, '', text, '', 'Rules:', ...RULES.map(r => `- ${r}`), '', CLOSE_OUT_HEAD, ...CLOSE_OUT.map(q => `- ${q}`)].join('\n'),
    background: [chain, '', 'Items in this task:', ...tracked.map(itemLine), ...(task.notes ? ['', `Notes: ${task.notes}`] : [])].join('\n'),
    reason: 'no live session or jr conversation on the task',
  };
}
