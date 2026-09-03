#!/usr/bin/env zx
// Stage 6: turn per-link ordinal judgments into one verdict. Free and deterministic —
// all arithmetic lives here, never in a prompt. See PLAN.md section 10.
//
// Usage: zx verdict.mjs [--cache ~/.cache/pr-classifier] [--verbose]

$.verbose = false;

const CACHE = (argv.cache ?? path.join(os.homedir(), '.cache/pr-classifier')).replace(
  /^~/,
  os.homedir()
);

// ---------------------------------------------------------------- the ladders

// Severity is ordinal, not a probability. Higher wins.
const SEVERITY = {good: 0, 'needs-changes': 1, bad: 2};
const NAME = ['good', 'needs-changes', 'bad'];

// What each judgment asserts, per link. `null` means the link abstains — it saw nothing
// either way, which is different from asserting "good".
const ASSERTS = {
  'description->code': {match: 'good', partial: 'needs-changes', mismatch: 'bad', unclear: null},
  conventions: {match: 'good', partial: 'needs-changes', mismatch: 'needs-changes', unclear: null},
  duplication: {match: 'good', partial: 'needs-changes', mismatch: 'needs-changes', unclear: null},
  'issue->rca': {match: 'good', partial: 'needs-changes', mismatch: 'bad', unclear: null},
  'rca->description': {match: 'good', partial: 'needs-changes', mismatch: 'bad', unclear: null},
};

// A link may never assert above its cap. A convention violation is real, but it does not
// on its own make a PR bad.
const CAPS = {
  'description->code': 'bad',
  conventions: 'needs-changes',
  duplication: 'needs-changes',
  'issue->rca': 'bad',
  'rca->description': 'bad',
};

const CONF = {low: 0, medium: 1, high: 2};

// Asymmetric on purpose. A false `needs-changes` costs one human glance; a false `good`
// ships a defect. So `good` must be earned, and a flag is cheap to raise.
const MIN_CONFIDENCE_FOR_GOOD = CONF.medium;
const MIN_COHERENCE = 0.4;

// An explicit `any` disables the type checker for everything downstream, so a PR carrying
// one is never simply `good`. The finding is deterministic (conventions.mjs greps for it),
// so the floor is applied here rather than trusted to a model that may read `any` as
// pragmatic. A floor, not a cap: it lifts `good` to `needs-changes` and leaves `bad` alone.
const ANY_TYPE_FLOOR = SEVERITY['needs-changes'];

// Ranking orders PRs from "ready to merge" down to "needs a human", so a reviewer works
// the list top to bottom. Separate from the verdict on purpose — a demo image cannot
// make a broken PR good, it only breaks ties between PRs that already passed.
const TIER = {good: 5, incomplete: 4, undecided: 3, 'needs-changes': 2, bad: 1, excluded: 0};
const POSITIVE = new Set(['good', 'incomplete', 'undecided']);

// Confidence pushes toward the ends of the list, it does not push up. Being *sure* a PR
// needs changes should sink it, not lift it above a PR we are merely unsure about.
// Tier spacing (10) exceeds the widest confidence swing (4), so tiers never interleave.
function rankOf(verdict, confidence, demoBonus) {
  const dir = verdict === 'excluded' ? 0 : POSITIVE.has(verdict) ? 1 : -1;
  return TIER[verdict] * 10 + dir * (CONF[confidence] ?? 0) * 2 + (demoBonus ? 1 : 0);
}

// ---------------------------------------------------------------- aggregate

function aggregate({timeline, links, ready}) {
  // Gate first: no intent statement means the ladder never ran.
  if (timeline.gate === 'excluded') {
    return {verdict: 'excluded', confidence: 'high', reason: timeline.excludedBy};
  }
  const coherence = timeline.evidence?.coherence ?? 0;
  if (coherence < MIN_COHERENCE) {
    return {verdict: 'undecided', confidence: 'high', reason: 'no-intent-statement'};
  }

  const asserted = [];
  for (const l of links) {
    const assertion = ASSERTS[l.link]?.[l.judgment];
    if (!assertion) continue; // abstained
    const capped = Math.min(SEVERITY[assertion], SEVERITY[CAPS[l.link] ?? 'bad']);
    asserted.push({link: l.link, severity: capped, confidence: CONF[l.confidence] ?? 0, judgment: l.judgment});
  }

  if (!asserted.length) {
    return {verdict: 'undecided', confidence: 'high', reason: 'every-link-abstained'};
  }

  // A link the work order marked ready but that never ran is NOT an abstention — it is a
  // check that did not happen. Silently calling such a PR `good` is exactly the expensive
  // error this design is built to avoid.
  const ranLinks = new Set(links.map((l) => l.link));
  const notRun = ready.filter((l) => !ranLinks.has(l));

  // The verdict is the worst link that spoke.
  const worst = Math.max(...asserted.map((a) => a.severity));
  const deciding = asserted.filter((a) => a.severity === worst);
  const conf = Math.max(...deciding.map((a) => a.confidence));

  // Deterministic findings outrank the ladder. An `any` is a fact about the diff, not a
  // judgement, so it is stated even when a ready link never ran — an absence of
  // information cannot outweigh a finding we already have in hand.
  const anyTypes = links.flatMap((l) => l.anyTypes ?? []);
  if (anyTypes.length && worst < ANY_TYPE_FLOOR) {
    return {
      verdict: NAME[ANY_TYPE_FLOOR],
      confidence: 'high',
      deciding: ['explicit-any'],
      reason: `explicit any on ${anyTypes.length} added line${anyTypes.length > 1 ? 's' : ''}`,
      anyTypes,
    };
  }
  // Past this point the ladder already reached the floor on its own.

  // `good` must mean every available check passed, not just the ones that are built.
  if (worst === SEVERITY.good && notRun.length) {
    return {
      verdict: 'incomplete',
      confidence: 'high',
      reason: `passed ${[...ranLinks].join(', ')}; never ran ${notRun.join(', ')}`,
      notRun,
    };
  }

  // Demand confidence before calling something good; never before flagging it.
  if (worst === SEVERITY.good && conf < MIN_CONFIDENCE_FOR_GOOD) {
    return {
      verdict: 'undecided',
      confidence: 'low',
      reason: 'good-but-unconfident',
      deciding: deciding.map((d) => d.link),
    };
  }

  return {
    verdict: NAME[worst],
    confidence: ['low', 'medium', 'high'][conf],
    deciding: deciding.map((d) => d.link),
    reason: deciding.map((d) => `${d.link}=${d.judgment}`).join(', '),
  };
}

// ---------------------------------------------------------------- main

const timelines = new Map(
  JSON.parse(fs.readFileSync(path.join(CACHE, 'timelines.json'), 'utf8')).timelines.map((t) => [t.key, t])
);

const VERDICT_DIR = path.join(CACHE, 'verdicts');
const byPr = new Map();
if (fs.existsSync(VERDICT_DIR)) {
  for (const f of fs.readdirSync(VERDICT_DIR).filter((f) => f.endsWith('.json'))) {
    const v = JSON.parse(fs.readFileSync(path.join(VERDICT_DIR, f), 'utf8'));
    if (!byPr.has(v.key)) byPr.set(v.key, []);
    byPr.get(v.key).push(v);
  }
}

if (!byPr.size) {
  console.error(chalk.red('no link verdicts yet — run classify.mjs --run first'));
  process.exit(1);
}

const rows = [];
const orders = new Map(
  JSON.parse(fs.readFileSync(path.join(CACHE, 'workorders.json'), 'utf8')).orders.map((o) => [o.key, o])
);

for (const [key, links] of byPr) {
  const timeline = timelines.get(key);
  if (!timeline) continue;
  const ready = (orders.get(key)?.links ?? [])
    .filter((l) => l.status === 'ready')
    .map((l) => l.link);
  const out = aggregate({timeline, links, ready});

  // A screenshot only counts where it can show something: on a frontend PR. Asking for
  // one on a migration or a config change would be noise.
  const hasFrontend = Boolean(orders.get(key)?.hasFrontend);
  const demo = timeline.demo ?? {hasImage: false, where: null};
  const demoBonus = hasFrontend && demo.hasImage;

  rows.push({
    key,
    url: timeline.url,
    population: timeline.population,
    outcome: timeline.outcome,
    ...out,
    // Recorded on every row, not only when the floor decided the verdict. The `any` is a
    // fact about the diff either way, and a reader should not have to infer it from the
    // reason string on the one path where it happened to be the deciding link.
    anyTypes: links.flatMap((l) => l.anyTypes ?? []),
    rank: rankOf(out.verdict, out.confidence, demoBonus),
    demo: {hasFrontend, ...demo, bonus: demoBonus},
    links: links.map((l) => ({link: l.link, judgment: l.judgment, confidence: l.confidence})),
    evidence: timeline.evidence,
  });
}

rows.sort((a, b) => b.rank - a.rank || a.key.localeCompare(b.key));

fs.writeFileSync(
  path.join(CACHE, 'classifications.json'),
  JSON.stringify({generatedAt: new Date().toISOString(), rows}, null, 1)
);

// ---------------------------------------------------------------- report

const n = rows.length;
const count = (f) => rows.filter(f).length;
const MARK = {
  good: chalk.green('good        '),
  incomplete: chalk.cyan('incomplete  '),
  'needs-changes': chalk.yellow('needs-changes'),
  bad: chalk.red('bad         '),
  undecided: chalk.dim('undecided   '),
  excluded: chalk.dim('excluded    '),
};

console.log(chalk.bold(`\nverdict  ${n} PRs\n`));

for (const v of ['good', 'incomplete', 'needs-changes', 'bad', 'undecided', 'excluded']) {
  const c = count((r) => r.verdict === v);
  if (c) console.log(`  ${MARK[v]} ${String(c).padStart(4)}  ${`${((c / n) * 100).toFixed(0)}%`.padStart(4)}`);
}

const decided = count((r) => ['good', 'needs-changes', 'bad'].includes(r.verdict));
console.log(chalk.bold('\nautomation rate'));
console.log(`  decided        ${String(decided).padStart(4)}  ${((decided / n) * 100).toFixed(0)}%`);
console.log(`  undecided      ${String(count((r) => r.verdict === 'undecided')).padStart(4)}  ${chalk.dim('a cost, not a safe default')}`);

console.log(chalk.bold('\nconfidence on decided'));
for (const c of ['high', 'medium', 'low']) {
  const k = count((r) => r.confidence === c && ['good', 'needs-changes', 'bad'].includes(r.verdict));
  if (k) console.log(`  ${c.padEnd(14)} ${String(k).padStart(4)}`);
}

const frontend = rows.filter((r) => r.demo?.hasFrontend);
if (frontend.length) {
  const shown = frontend.filter((r) => r.demo.bonus).length;
  console.log(chalk.bold('\ndemo image  (frontend PRs)'));
  console.log(`  demonstrated   ${String(shown).padStart(4)}  ${((shown / frontend.length) * 100).toFixed(0)}%  ${chalk.dim('ranks above its peers')}`);
  console.log(`  no image       ${String(frontend.length - shown).padStart(4)}  ${chalk.dim('not a defect, just weaker evidence')}`);
}

const anyRows = rows.filter((r) => r.anyTypes?.length);
if (anyRows.length) {
  console.log(chalk.bold('\nexplicit any  (deterministic downgrade)'));
  for (const r of anyRows) {
    console.log(`  ${chalk.red(String(r.anyTypes.length).padStart(3))}  ${r.key}`);
  }
}

if (argv.verbose) {
  console.log(chalk.bold('\nflagged'));
  for (const r of rows.filter((r) => r.verdict === 'needs-changes' || r.verdict === 'bad')) {
    console.log(`  ${MARK[r.verdict]} ${r.confidence.padEnd(6)} ${r.key}`);
    console.log(chalk.dim(`      ${r.reason}`));
  }
}

console.log(chalk.dim(`\n  -> ${path.join(CACHE, 'classifications.json')}`));
