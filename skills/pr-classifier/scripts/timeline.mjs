#!/usr/bin/env zx
// Turn cached PR records into feedback timelines. No model calls: this is pure data.
//   - drops PRs the getsantry cleanup bot closed
//   - removes bot comments, but mines them for issue links first
//   - splits commits into pre-feedback and post-feedback groups
//   - computes a deterministic evidence score (see PLAN.md section 10)
// Usage: zx timeline.mjs [--cache ~/.cache/pr-classifier] [--author ryan953] [--verbose]

$.verbose = false;

const ME = argv.author ?? 'ryan953';
const CACHE = (argv.cache ?? path.join(os.homedir(), '.cache/pr-classifier')).replace(
  /^~/,
  os.homedir()
);
const OUT_DIR = path.join(CACHE, 'timeline');
const PR_DIR = path.join(CACHE, 'prs');

// ---------------------------------------------------------------- bot rules

const CLEANUP_BOT = 'getsantry';
const STALE_RE = /gone \w+ weeks? without activity/i;

const BOTS = new Set([
  CLEANUP_BOT,
  'github-actions',
  'linear-code',
  'cursor',
  'codecov',
  'codecov-commenter',
  'sentry-io',
  'seer-by-sentry',
  'sentry-autofix',
]);

const BOT_MARKERS = [
  '<!-- TYPE_COVERAGE_DIFF -->',
  '<!-- STORIES_PREVIEW -->',
  '<!-- FRONTEND_BACKEND_WARNING -->',
  '<!-- craft-changelog-preview -->',
  '<!-- linear-linkback -->',
];

// A close the author explains as a move, not a rejection. See PLAN.md section 3.
const SUPERSEDED_RE =
  /\b(superseded|supersedes|landed directly|in favou?r of|folding (?:this )?into|no PR needed|moved to|replaced by)\b/i;

const isBot = (login) => !login || BOTS.has(login) || /\[bot\]$/.test(login);
const isBotBody = (body) => BOT_MARKERS.some((m) => (body ?? '').includes(m));

// Agents open PRs under their own accounts, and Seer stamps its PR bodies.
const AGENT_AUTHORS = new Set(['sentry', 'sentry-junior', 'seer-by-sentry', 'cursor']);
const SEER_STAMP = /seerDrawer|Comment `@sentry|@sentry <feedback>/;

/**
 * Which population is this PR in? Coverage of the issue -> RCA rungs depends almost
 * entirely on this, so the classifier routes on it. See PLAN.md section 0.
 */
function population(pr, me) {
  const author = pr.author?.login;
  if (AGENT_AUTHORS.has(author) || /\[bot\]$/.test(author ?? '') || SEER_STAMP.test(pr.body ?? '')) {
    return 'agent-authored';
  }
  return author === me ? 'own' : 'reviewed-human';
}

// ---------------------------------------------------------------- link mining

const LINK_RE = {
  linear: /linear\.app\/[\w-]+\/issue\/([A-Z][A-Z0-9]*-\d+)/g,
  sentryIssue: /sentry\.io\/(?:organizations\/[\w-]+\/)?issues\/(\d+)/g,
  shortId: /\b(?:Fixes|Closes|Resolves)\s+([A-Z][A-Z0-9]{1,}-[A-Z0-9]{2,})\b/g,
};

// Not global: used with .test(), which would otherwise advance lastIndex between calls.
const SEER_RE = /\b(?:seer|autofix|root cause analysis|rca)\b/i;

/** Pull every upstream-issue anchor out of the PR body plus all comments, bots included. */
function mineLinks(pr) {
  const haystacks = [
    pr.body ?? '',
    ...(pr.comments?.nodes ?? []).map((c) => c.body ?? ''),
    ...(pr.reviews?.nodes ?? []).map((r) => r.body ?? ''),
  ];

  const grab = (re) => {
    const hits = new Set();
    for (const h of haystacks) for (const m of h.matchAll(re)) hits.add(m[1]);
    return [...hits];
  };

  const links = {
    linear: grab(LINK_RE.linear),
    sentryIssue: grab(LINK_RE.sentryIssue),
    shortId: grab(LINK_RE.shortId),
    githubIssue: (pr.closingIssuesReferences?.nodes ?? []).map((n) => n.number),
    mentionsSeer: haystacks.some((h) => SEER_RE.test(h)),
  };
  links.hasAnchor =
    links.linear.length + links.sentryIssue.length + links.shortId.length + links.githubIssue.length >
    0;
  return links;
}

// ---------------------------------------------------------------- timeline

/** Did the cleanup bot close this? Such PRs carry no human signal at all. */
function cleanupBotClosed(pr) {
  const byActor = (pr.timelineItems?.nodes ?? []).some(
    (n) => n?.actor?.login === CLEANUP_BOT
  );
  const byComment = (pr.comments?.nodes ?? []).some(
    (c) => c?.author?.login === CLEANUP_BOT && STALE_RE.test(c.body ?? '')
  );
  return byActor || byComment;
}

/** Build the sorted feedback stream. Author self-narration is not feedback. */
function feedbackEvents(pr, authorLogin) {
  const events = [];

  for (const c of pr.comments?.nodes ?? []) {
    const login = c?.author?.login;
    if (isBot(login) || isBotBody(c.body)) continue;
    if (login === authorLogin) continue; // self-narration, not feedback
    events.push({at: c.createdAt, kind: 'comment', actor: login, polarity: 'neutral'});
  }

  for (const r of pr.reviews?.nodes ?? []) {
    const login = r?.author?.login;
    if (isBot(login)) continue;
    if (login === authorLogin) continue;
    const inline = r.comments?.nodes?.length ?? 0;
    let polarity = 'neutral';
    if (r.state === 'APPROVED') polarity = 'support';
    else if (r.state === 'CHANGES_REQUESTED') polarity = 'change-request';
    else if (inline > 0) polarity = 'change-request';
    events.push({at: r.createdAt, kind: 'review', actor: login, polarity, state: r.state, inline});
  }

  if (pr.mergedAt) {
    events.push({
      at: pr.mergedAt,
      kind: 'merge',
      actor: pr.mergedBy?.login,
      polarity: 'support',
    });
  } else if (pr.closedAt) {
    const lastHuman = [...(pr.comments?.nodes ?? [])]
      .filter((c) => !isBot(c?.author?.login) && !isBotBody(c.body))
      .pop();
    const closer = (pr.timelineItems?.nodes ?? []).at(-1)?.actor?.login;
    const selfClosed = closer === authorLogin;
    const excuse = SUPERSEDED_RE.test(lastHuman?.body ?? '') || SUPERSEDED_RE.test(pr.body ?? '');
    events.push({
      at: pr.closedAt,
      kind: 'close',
      actor: closer,
      polarity: selfClosed && excuse ? 'superseded' : 'negative',
      reason: excuse ? (lastHuman?.body ?? '').slice(0, 120).replace(/\s+/g, ' ') : undefined,
    });
  }

  return events.sort((a, b) => new Date(a.at) - new Date(b.at));
}

// ---------------------------------------------------------------- evidence

// Free, deterministic. A model cannot hallucinate any of these. PLAN.md section 10.
//
// TWO axes, not one. The corpus proved they come apart: 42 PRs have a rich description
// and a tractable diff but zero human comments. The description -> code ladder runs on
// those perfectly well. They are silent, not unjudgeable.
//
//   coherence — can the ladder run at all?   (description, diff, anchor)
//   reception — can we read how it landed?   (comments, reviews, outcome)
//
// Only coherence gates. Low reception is a finding, not a refusal to decide.
const COHERENCE_WEIGHTS = {
  descriptionRich: 0.45, // body >= 200 chars: a real intent statement
  descriptionThin: 0.2, // body >= 40 chars
  diffTractable: 0.35, // changed files, and under the size cap
  anchorPresent: 0.2, // an upstream issue, so the top rungs exist too
};
const RECEPTION_WEIGHTS = {
  humanFeedback: 0.4, // at least one non-author, non-bot comment or review
  moreFeedback: 0.25, // two or more of them
  reviewSignal: 0.2, // an explicit approve or changes-requested
  outcomeKnown: 0.15, // merged, or closed by a human
};
const DIFF_CAP_LINES = 2000;

function scoreEvidence({pr, events, links}) {
  const human = events.filter((e) => e.kind === 'comment' || e.kind === 'review');
  const body = pr.body ?? '';
  const churn = (pr.additions ?? 0) + (pr.deletions ?? 0);

  const signals = {
    descriptionRich: body.length >= 200,
    descriptionThin: body.length >= 40 && body.length < 200,
    diffTractable: (pr.changedFiles ?? 0) > 0 && churn <= DIFF_CAP_LINES,
    anchorPresent: links.hasAnchor,
    humanFeedback: human.length >= 1,
    moreFeedback: human.length >= 2,
    reviewSignal: events.some((e) => e.polarity === 'support' || e.polarity === 'change-request'),
    outcomeKnown: Boolean(pr.mergedAt || pr.closedAt),
  };

  const sum = (weights) =>
    Math.min(
      1,
      Number(
        Object.entries(weights)
          .reduce((acc, [k, w]) => acc + (signals[k] ? w : 0), 0)
          .toFixed(3)
      )
    );

  return {coherence: sum(COHERENCE_WEIGHTS), reception: sum(RECEPTION_WEIGHTS), signals};
}

const band = (s) => (s >= 0.7 ? 'high' : s >= 0.4 ? 'medium' : 'low');

// ---------------------------------------------------------------- per PR

function buildTimeline(record) {
  const pr = record.pr;
  const authorLogin = pr.author?.login;
  const links = mineLinks(pr);

  if (cleanupBotClosed(pr)) {
    return {
      key: record._meta.key,
      url: pr.url,
      outcome: 'excluded',
      population: population(pr, ME),
      excludedBy: 'getsantry-cleanup-bot',
      evidence: {coherence: 0, reception: 0},
      evidenceBand: {coherence: 'low', reception: 'low'},
      gate: 'excluded',
      links,
    };
  }

  const events = feedbackEvents(pr, authorLogin);
  const firstFeedbackAt = events.find((e) => e.kind === 'comment' || e.kind === 'review')?.at ?? null;
  const cutoff = firstFeedbackAt ? new Date(firstFeedbackAt) : null;

  const commits = (pr.commits?.nodes ?? []).map((n) => n.commit).filter(Boolean);
  const pre = [];
  const post = [];
  let rebaseSuspected = false;

  for (const c of commits) {
    if (!cutoff) {
      pre.push(c.oid);
      continue;
    }
    const committed = new Date(c.committedDate);
    const authored = new Date(c.authoredDate ?? c.committedDate);
    if (committed >= cutoff) {
      // A rebase rewrites committedDate. If the work was authored before the
      // feedback, it is not a response to it.
      if (authored < cutoff) {
        rebaseSuspected = true;
        pre.push(c.oid);
      } else {
        post.push(c.oid);
      }
    } else {
      pre.push(c.oid);
    }
  }

  const closeEvent = events.find((e) => e.kind === 'close');
  const outcome = pr.mergedAt
    ? 'merged'
    : closeEvent?.polarity === 'superseded'
      ? 'superseded'
      : pr.closedAt
        ? 'closed'
        : 'open';

  const {coherence, reception, signals} = scoreEvidence({pr, events, links});

  return {
    key: record._meta.key,
    url: pr.url,
    title: pr.title,
    roles: record._meta.roles,
    author: authorLogin,
    population: population(pr, ME),
    outcome,
    firstFeedbackAt,
    preCommits: pre,
    postCommits: post,
    rebaseSuspected,
    feedbackEvents: events,
    polarities: [...new Set(events.map((e) => e.polarity))],
    links,
    evidence: {coherence, reception},
    evidenceBand: {coherence: band(coherence), reception: band(reception)},
    evidenceSignals: signals,
    // Only coherence gates. Silence is a reception finding, not a refusal to decide.
    gate: coherence < 0.4 ? 'undecided-no-intent' : 'proceed',
    stats: {
      commits: commits.length,
      changedFiles: pr.changedFiles ?? 0,
      churn: (pr.additions ?? 0) + (pr.deletions ?? 0),
      bodyLength: (pr.body ?? '').length,
    },
  };
}

// ---------------------------------------------------------------- main

if (!fs.existsSync(PR_DIR)) {
  console.error(chalk.red(`no cache at ${PR_DIR} — run harvest.mjs first`));
  process.exit(1);
}
fs.mkdirSync(OUT_DIR, {recursive: true});

const files = fs.readdirSync(PR_DIR).filter((f) => f.endsWith('.json'));
const results = [];

for (const f of files) {
  let record;
  try {
    record = JSON.parse(fs.readFileSync(path.join(PR_DIR, f), 'utf8'));
  } catch (e) {
    console.error(chalk.red(`  ! ${f}: ${e.message}`));
    continue;
  }
  const t = buildTimeline(record);
  fs.writeFileSync(path.join(OUT_DIR, f), JSON.stringify(t, null, 1));
  results.push(t);
}

fs.writeFileSync(
  path.join(CACHE, 'timelines.json'),
  JSON.stringify({generatedAt: new Date().toISOString(), timelines: results}, null, 1)
);

// ---------------------------------------------------------------- report

const count = (f) => results.filter(f).length;
const pct = (n) => `${((n / results.length) * 100).toFixed(0)}%`.padStart(4);

console.log(chalk.bold(`\ntimeline  ${results.length} PRs\n`));

console.log(chalk.bold('outcome'));
for (const o of ['merged', 'superseded', 'closed', 'excluded', 'open']) {
  const n = count((r) => r.outcome === o);
  if (n) console.log(`  ${o.padEnd(12)} ${String(n).padStart(4)}  ${pct(n)}`);
}

console.log(chalk.bold('\nevidence  (two axes: they come apart)'));
for (const axis of ['coherence', 'reception']) {
  const cells = ['high', 'medium', 'low']
    .map((b) => `${b} ${String(count((r) => r.evidenceBand?.[axis] === b)).padStart(3)}`)
    .join('   ');
  console.log(`  ${axis.padEnd(10)} ${cells}`);
}
const silent = count((r) => r.evidenceBand?.coherence === 'high' && r.evidenceBand?.reception === 'low');
console.log(chalk.dim(`  ${silent} PRs are judgeable but silent (high coherence, low reception)`));

console.log(chalk.bold('\ngate'));
for (const g of ['proceed', 'undecided-no-intent', 'excluded']) {
  const n = count((r) => r.gate === g);
  if (n) console.log(`  ${g.padEnd(24)} ${String(n).padStart(4)}  ${pct(n)}`);
}

console.log(chalk.bold('\npopulation  (anchor rate drives the routing)'));
for (const p of ['own', 'agent-authored', 'reviewed-human']) {
  const rows = results.filter((r) => r.population === p);
  if (!rows.length) continue;
  const anchored = rows.filter((r) => r.links?.hasAnchor).length;
  const rate = `${((anchored / rows.length) * 100).toFixed(0)}%`;
  console.log(`  ${p.padEnd(16)} ${String(rows.length).padStart(4)}   anchored ${String(anchored).padStart(3)}  ${rate.padStart(4)}`);
}

console.log(chalk.bold('\nanchors  (the issue -> RCA rungs)'));
console.log(`  any anchor    ${String(count((r) => r.links?.hasAnchor)).padStart(4)}`);
console.log(`  linear        ${String(count((r) => r.links?.linear?.length)).padStart(4)}`);
console.log(`  sentry issue  ${String(count((r) => r.links?.sentryIssue?.length)).padStart(4)}`);
console.log(`  short id      ${String(count((r) => r.links?.shortId?.length)).padStart(4)}`);
console.log(`  gh issue      ${String(count((r) => r.links?.githubIssue?.length)).padStart(4)}`);

console.log(chalk.bold('\nfeedback split'));
console.log(`  had feedback  ${String(count((r) => r.firstFeedbackAt)).padStart(4)}`);
console.log(`  post commits  ${String(count((r) => r.postCommits?.length)).padStart(4)}`);
console.log(`  rebase flag   ${String(count((r) => r.rebaseSuspected)).padStart(4)}`);

console.log(chalk.dim(`\n  -> ${OUT_DIR}`));

if (argv.verbose) {
  console.log(chalk.bold('\nsuperseded closes'));
  for (const r of results.filter((r) => r.outcome === 'superseded')) {
    console.log(`  ${r.key}\n    ${chalk.dim(r.feedbackEvents.find((e) => e.kind === 'close')?.reason ?? '')}`);
  }
}
