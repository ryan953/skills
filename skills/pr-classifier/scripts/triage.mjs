#!/usr/bin/env zx
// Stage 2: decide what work each PR needs, and drop the ones not worth grading.
// Runs entirely offline — harvest already cached the file lists, so this costs nothing
// and makes no network call. Output is a work order per PR for the model stages.
//
// Usage: zx triage.mjs [--cache ~/.cache/pr-classifier] [--population agent-authored]
//                      [--fetch-diffs] [--limit N] [--verbose]

$.verbose = false;

const CACHE = (argv.cache ?? path.join(os.homedir(), '.cache/pr-classifier')).replace(
  /^~/,
  os.homedir()
);
const PR_DIR = path.join(CACHE, 'prs');
const DIFF_DIR = path.join(CACHE, 'diffs');
const OUT = path.join(CACHE, 'workorders.json');
const CODE_ROOT = path.join(os.homedir(), 'code');

const DIFF_CAP_LINES = 2000;
const MIN_REVIEWABLE_FILES = 1;

// ---------------------------------------------------------------- file rules

// Generated or vendored. Real, but not worth a model's attention.
const NOISE = [
  /(^|\/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock|poetry\.lock|uv\.lock)$/,
  /(^|\/)__snapshots__\//,
  /\.snap$/,
  /\.min\.(js|css)$/,
  /(^|\/)(dist|build|vendor|node_modules)\//,
  /(^|\/)migrations\/\d+/,
  /\.(po|mo|pot)$/,
  /\.pb\.(go|py|ts)$/,
  /(^|\/)generated\//,
  /\.lock$/,
];

const LANG = {
  ts: /\.tsx?$/,
  js: /\.jsx?$/,
  py: /\.py$/,
  css: /\.(css|less|scss)$/,
  md: /\.mdx?$/,
  cfg: /\.(json|ya?ml|toml|ini)$/,
};

const TEST_FILE = /(\.spec\.|\.test\.|(^|\/)tests?\/|_test\.py$|(^|\/)test_)/;

const isNoise = (p) => NOISE.some((re) => re.test(p));
const langOf = (p) => Object.keys(LANG).find((k) => LANG[k].test(p)) ?? 'other';

// ---------------------------------------------------------------- AGENTS.md scopes

/** Map repo -> its AGENTS.md paths, read once from the local checkout when present. */
const agentsCache = new Map();
function agentsScopes(repo) {
  if (agentsCache.has(repo)) return agentsCache.get(repo);
  const root = path.join(CODE_ROOT, repo);
  let scopes = [];
  if (fs.existsSync(root)) {
    try {
      scopes = fs
        .readdirSync(root, {recursive: true, withFileTypes: true})
        .filter((d) => d.isFile() && d.name === 'AGENTS.md')
        .map((d) => path.relative(root, path.join(d.parentPath ?? d.path, d.name)))
        .filter((p) => !p.includes('node_modules') && !p.includes('.claude/worktrees'));
    } catch {
      scopes = [];
    }
  }
  agentsCache.set(repo, scopes);
  return scopes;
}

/** Longest-prefix match: which AGENTS.md files govern these changed paths? */
function scopesFor(repo, paths) {
  const all = agentsScopes(repo);
  if (!all.length) return [];
  const hit = new Set();
  for (const f of paths) {
    for (const a of all) {
      const dir = path.dirname(a) === '.' ? '' : `${path.dirname(a)}/`;
      if (f.startsWith(dir)) hit.add(a);
    }
  }
  return [...hit].sort((a, b) => a.split('/').length - b.split('/').length);
}

// ---------------------------------------------------------------- triage

function triage(record, timeline) {
  const pr = record.pr;
  const repo = record._meta.repo;
  const files = (pr.files?.nodes ?? []).map((f) => f.path);

  const reviewable = files.filter((f) => !isNoise(f));
  const noise = files.length - reviewable.length;
  const tests = reviewable.filter((f) => TEST_FILE.test(f));

  const languages = {};
  for (const f of reviewable) languages[langOf(f)] = (languages[langOf(f)] ?? 0) + 1;

  const churn = (pr.additions ?? 0) + (pr.deletions ?? 0);
  const hasFrontend = reviewable.some((f) => LANG.ts.test(f) || LANG.js.test(f));

  // ---- fail-fast exits, cheapest first
  let skip = null;
  if (timeline.gate === 'excluded') skip = 'cleanup-bot';
  else if (timeline.gate === 'undecided-no-intent') skip = 'no-intent-statement';
  else if (reviewable.length < MIN_REVIEWABLE_FILES) skip = 'all-generated';
  else if (churn > DIFF_CAP_LINES) skip = 'diff-over-cap';
  else if (files.length >= 100) skip = 'file-list-truncated'; // GraphQL page limit hit

  // ---- which links can actually run
  const links = [];
  const anchors = timeline.links ?? {};
  if (anchors.hasAnchor) {
    links.push({link: 'issue->rca', status: 'blocked', needs: 'sentry-issue-fetch'});
    links.push({link: 'rca->description', status: 'blocked', needs: 'sentry-issue-fetch'});
  }
  if (timeline.evidenceSignals?.descriptionRich || timeline.evidenceSignals?.descriptionThin) {
    links.push({link: 'description->code', status: 'ready', needs: 'diff'});
  }
  if (hasFrontend) {
    links.push({
      link: 'conventions',
      status: 'ready',
      needs: 'diff',
      cap: 'needs-changes', // a convention violation never reaches `bad` on its own
      agentsMd: scopesFor(repo, reviewable),
    });
  }

  return {
    key: record._meta.key,
    url: pr.url,
    population: timeline.population,
    outcome: timeline.outcome,
    skip,
    links: skip ? [] : links,
    runnable: skip ? 0 : links.filter((l) => l.status === 'ready').length,
    files: {
      total: files.length,
      reviewable: reviewable.length,
      noise,
      tests: tests.length,
      truncated: files.length >= 100,
    },
    languages,
    churn,
    hasFrontend,
    paths: reviewable.slice(0, 40),
  };
}

// ---------------------------------------------------------------- diff warming

async function fetchDiff(order) {
  const [owner, repo, num] = order.key.split('__');
  const file = path.join(DIFF_DIR, `${order.key}.diff`);
  if (fs.existsSync(file)) return 'cached';
  const res = await $`gh pr diff ${num} --repo ${owner}/${repo}`.nothrow();
  if (res.exitCode !== 0) return 'failed';
  fs.writeFileSync(file, res.stdout);
  return 'fetched';
}

// ---------------------------------------------------------------- main

const timelines = JSON.parse(fs.readFileSync(path.join(CACHE, 'timelines.json'), 'utf8')).timelines;
const byKey = new Map(timelines.map((t) => [t.key, t]));

const orders = [];
for (const f of fs.readdirSync(PR_DIR).filter((f) => f.endsWith('.json'))) {
  const record = JSON.parse(fs.readFileSync(path.join(PR_DIR, f), 'utf8'));
  const t = byKey.get(record._meta.key);
  if (!t) continue;
  orders.push(triage(record, t));
}

let selected = orders;
if (argv.population) selected = selected.filter((o) => o.population === argv.population);
if (argv.key) selected = selected.filter((o) => o.key.includes(String(argv.key)));

fs.writeFileSync(
  OUT,
  JSON.stringify({generatedAt: new Date().toISOString(), orders}, null, 1)
);

// ---------------------------------------------------------------- report

const n = orders.length;
const count = (f) => orders.filter(f).length;
const pct = (x) => `${((x / n) * 100).toFixed(0)}%`.padStart(4);

console.log(chalk.bold(`\ntriage  ${n} PRs  (offline, no network)\n`));

console.log(chalk.bold('fail-fast exits'));
const skipped = count((o) => o.skip);
for (const r of ['cleanup-bot', 'no-intent-statement', 'all-generated', 'diff-over-cap', 'file-list-truncated']) {
  const k = count((o) => o.skip === r);
  if (k) console.log(`  ${r.padEnd(22)} ${String(k).padStart(4)}  ${pct(k)}`);
}
console.log(`  ${chalk.bold('reach the model'.padEnd(22))} ${String(n - skipped).padStart(4)}  ${pct(n - skipped)}`);

console.log(chalk.bold('\nrunnable links per PR'));
for (const k of [0, 1, 2, 3, 4]) {
  const c = count((o) => o.links.length === k);
  if (c) console.log(`  ${k} link${k === 1 ? ' ' : 's'}              ${String(c).padStart(4)}  ${pct(c)}`);
}

console.log(chalk.bold('\nlink coverage  (of PRs that reach the model)'));
const live = orders.filter((o) => !o.skip);
for (const l of ['issue->rca', 'rca->description', 'description->code', 'conventions']) {
  const c = live.filter((o) => o.links.some((x) => x.link === l)).length;
  const blocked = live.filter((o) => o.links.some((x) => x.link === l && x.status === 'blocked')).length;
  console.log(
    `  ${l.padEnd(20)} ${String(c).padStart(4)}  ${`${((c / live.length) * 100).toFixed(0)}%`.padStart(4)}` +
      (blocked ? chalk.dim(`   ${blocked} blocked on a Sentry fetch`) : '')
  );
}

console.log(chalk.bold('\nby population  (reaching the model)'));
for (const p of ['own', 'agent-authored', 'reviewed-human']) {
  const rows = live.filter((o) => o.population === p);
  if (!rows.length) continue;
  const full = rows.filter((o) => o.links.length >= 3).length;
  console.log(`  ${p.padEnd(16)} ${String(rows.length).padStart(4)}   full ladder ${String(full).padStart(3)}`);
}

console.log(chalk.bold('\nnoise stripped'));
console.log(`  PRs with generated files  ${String(count((o) => o.files.noise > 0)).padStart(4)}`);
console.log(`  total generated files     ${String(orders.reduce((a, o) => a + o.files.noise, 0)).padStart(4)}`);
console.log(`  frontend PRs (conventions)${String(count((o) => o.hasFrontend)).padStart(4)}`);

console.log(chalk.dim(`\n  -> ${OUT}`));

if (argv['fetch-diffs']) {
  const targets = selected.filter((o) => !o.skip).slice(0, Number(argv.limit ?? 25));
  fs.mkdirSync(DIFF_DIR, {recursive: true});
  console.log(chalk.bold(`\nwarming ${targets.length} diffs...`));
  const tally = {cached: 0, fetched: 0, failed: 0};
  for (const o of targets) tally[await fetchDiff(o)]++;
  console.log(`  fetched ${tally.fetched}  cached ${tally.cached}  failed ${tally.failed}`);
  console.log(chalk.dim(`  -> ${DIFF_DIR}`));
}
