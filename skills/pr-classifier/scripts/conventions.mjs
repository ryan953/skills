#!/usr/bin/env zx
// Stage 5: the conventions link. Does the diff obey AGENTS.md and the frontend
// conventions?
//
// Reuses the `frontend-conventions` skill's rule docs and its exact regex gate table,
// rather than invoking that skill's subagent fan-out. The fan-out is right for reviewing
// one branch interactively; it is far too expensive per PR for a batch classifier, and the
// gate is deterministic either way. Same rules, same gate, one cheap call.
//
// Capped at `needs-changes`: a convention violation never makes a PR `bad` on its own.
//
// Usage: zx conventions.mjs [--key 123191] [--population agent-authored] [--limit 25]
//                           [--run] [--concurrency 6]

$.verbose = false;

const CACHE = (argv.cache ?? path.join(os.homedir(), '.cache/pr-classifier')).replace(
  /^~/,
  os.homedir()
);
const DIFF_DIR = path.join(CACHE, 'diffs');
const OUT_DIR = path.join(CACHE, 'verdicts');
const FC = path.join(os.homedir(), '.claude/skills/frontend-conventions');
const CODE_ROOT = path.join(os.homedir(), 'code');

const MODEL = argv.model ?? 'haiku';
const CONCURRENCY = Number(argv.concurrency ?? 6);
const DIFF_CHAR_CAP = 24000;

// The gate table from frontend-conventions/SKILL.md, verbatim. Deterministic and free —
// it decides which rule docs are even relevant before any model sees the diff.
const CATEGORIES = [
  {
    name: 'code style',
    test: () => true,
    docs: [
      'inline-exports.md',
      'no-unnecessary-intermediates.md',
      'consistent-destructuring.md',
      'no-unnecessary-renames.md',
      'no-thin-wrapper-hooks.md',
    ],
  },
  {
    name: 'api usage',
    test: (d) => /useQuery|useQueries|useMutation|useApiQuery|apiOptions|mutationOptions|@tanstack\/react-query/.test(d),
    docs: ['api-calls.md', 'react-query-patterns.md'],
  },
  {
    name: 'ui components',
    test: (d) => /\bstyled\b|<div|<span|<h[1-6]|<p[\s>]|<img/.test(d),
    docs: [
      'prefer-layout-components.md',
      'prefer-typography-components.md',
      'prefer-core-assets.md',
      'icons-and-images.md',
    ],
  },
  {
    name: 'react patterns',
    test: (d) => /createContext|\.Provider|\.Consumer|\.displayName/.test(d),
    docs: ['modern-context-patterns.md'],
  },
  {
    name: 'url state',
    test: (d) => /useQueryParamState|useLocationQuery|updateLocation|updateNullableLocation|decodeScalar|decodeList|decodeInteger|decodeSorts|useUrlParams|location\.query/.test(d),
    docs: ['prefer-nuqs-url-state.md'],
  },
  {
    name: 'code comments',
    test: (d) => /^\+.*(\/\/|\/\*|\{\/\*)/m.test(d),
    docs: ['code-comments.md'],
  },
  {
    name: 'testing',
    test: (d, o) => o.paths.some((p) => /\.spec\.|\.test\./.test(p)),
    docs: ['testing-guidelines.md'],
  },
];

const SYSTEM = `You check one thing: does this diff obey the project's stated conventions?

You are given the project's AGENTS.md files and the specific convention rules that apply
to this diff. Judge ONLY against those documents. Do not invent conventions, and do not
review correctness, naming taste, or architecture — other stages do that.

Only flag lines the diff ADDS (lines starting with +). Do not flag pre-existing code.

Your entire response must be ONE JSON object. Nothing before it, nothing after it.

{
  "judgment": "match" | "partial" | "mismatch" | "unclear",
  "confidence": "low" | "medium" | "high",
  "violations": [{"file": "", "rule": "", "detail": ""}],
  "note": ""
}

judgment:
  match      no convention violations in the added lines
  partial    minor or arguable violations
  mismatch   clear violations of a stated rule
  unclear    the diff is too small or too opaque to judge against these rules

Cite the rule you are applying by its document or AGENTS.md heading. If you cannot point
at a specific stated rule, it is not a violation — say "match".

Each rule doc may carry an "Exceptions — do NOT flag these" section. Read it before you
flag anything, and drop any finding it covers. An exception is part of the rule, not a
loophole; a rule doc's exceptions outrank its headline sentence.

If a line partly follows a rule and partly does not, that is "partial", not "mismatch".
Reserve "mismatch" for a clear, unambiguous breach of a stated rule.

An empty violations array is correct and common. Most diffs obey the conventions.`;

// ---------------------------------------------------------------- inputs

const orders = JSON.parse(fs.readFileSync(path.join(CACHE, 'workorders.json'), 'utf8')).orders;

let pool = orders.filter(
  (o) => !o.skip && o.links.some((l) => l.link === 'conventions') &&
    fs.existsSync(path.join(DIFF_DIR, `${o.key}.diff`))
);
if (argv.population) pool = pool.filter((o) => o.population === argv.population);
if (argv.key) pool = pool.filter((o) => o.key.includes(String(argv.key)));
const selected = pool.slice(0, Number(argv.limit ?? 25));

if (!selected.length) {
  console.error(chalk.red('nothing to check. Warm diffs first, and check the PR has JS/TS files.'));
  process.exit(1);
}

const ruleCache = new Map();
function readRule(doc) {
  if (!ruleCache.has(doc)) {
    ruleCache.set(doc, fs.readFileSync(path.join(FC, 'rules', doc), 'utf8'));
  }
  return ruleCache.get(doc);
}

const agentsCache = new Map();
function readAgents(repo, rel) {
  const k = `${repo}/${rel}`;
  if (!agentsCache.has(k)) {
    const p = path.join(CODE_ROOT, repo, rel);
    agentsCache.set(k, fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '');
  }
  return agentsCache.get(k);
}

function build(order) {
  const diff = fs.readFileSync(path.join(DIFF_DIR, `${order.key}.diff`), 'utf8').slice(0, DIFF_CHAR_CAP);
  const repo = order.key.split('__')[1];
  const link = order.links.find((l) => l.link === 'conventions');

  const fired = CATEGORIES.filter((c) => c.test(diff, order));
  const docs = [...new Set(fired.flatMap((c) => c.docs))];

  const agents = (link.agentsMd ?? [])
    .map((rel) => ({rel, text: readAgents(repo, rel)}))
    .filter((a) => a.text);

  const user = `<agents_md>
${agents.map((a) => `--- ${a.rel} ---\n${a.text}`).join('\n\n')}
</agents_md>

<convention_rules>
${docs.map((d) => `--- ${d} ---\n${readRule(d)}`).join('\n\n')}
</convention_rules>

<changed_files>
${order.paths.join('\n')}
</changed_files>

<diff>
${diff}
</diff>`;

  return {order, user, categories: fired.map((c) => c.name), docs, agents: agents.map((a) => a.rel)};
}

const jobs = selected.map(build);

// ---------------------------------------------------------------- dry run

if (!argv.run) {
  console.log(chalk.bold(`\nconventions  dry run  ${jobs.length} PRs\n`));
  for (const j of jobs) {
    console.log(`  ${j.order.key}`);
    console.log(chalk.dim(`    categories: ${j.categories.join(', ')}`));
    console.log(chalk.dim(`    rules     : ${j.docs.length} docs, ${Math.round(j.user.length / 3.7)} tok prompt`));
    console.log(chalk.dim(`    agents.md : ${j.agents.join(', ') || 'none'}`));
  }
  console.log(chalk.dim('\n  add --run to execute'));
  process.exit(0);
}

// ---------------------------------------------------------------- run

function extractLast(text) {
  const found = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== '{') continue;
    let depth = 0, inStr = false, esc = false;
    for (let j = i; j < text.length; j++) {
      const c = text[j];
      if (esc) { esc = false; continue; }
      if (c === '\\') { esc = true; continue; }
      if (c === '"') { inStr = !inStr; continue; }
      if (inStr) continue;
      if (c === '{') depth++;
      else if (c === '}') { depth--; if (depth === 0) { found.push(text.slice(i, j + 1)); i = j; break; } }
    }
  }
  for (const c of found.reverse()) {
    try {
      const v = JSON.parse(c);
      if (['match', 'partial', 'mismatch', 'unclear'].includes(v.judgment)) return v;
    } catch { /* keep scanning */ }
  }
  return null;
}

fs.mkdirSync(OUT_DIR, {recursive: true});
console.log(chalk.bold(`\nconventions  ${jobs.length} PRs  model=${MODEL}  concurrency=${CONCURRENCY}\n`));

const MARK = {
  match: chalk.green('clean   '),
  partial: chalk.yellow('minor   '),
  mismatch: chalk.red('violates'),
  unclear: chalk.dim('unclear '),
};

let cost = 0, done = 0, cursor = 0;
const results = [];

async function worker() {
  while (cursor < jobs.length) {
    const j = jobs[cursor++];
    const res = await $({env: {...process.env, MAX_THINKING_TOKENS: '0'}})`claude -p ${j.user} --model ${MODEL} --system-prompt ${SYSTEM} --output-format json --allowedTools ${''}`
      .nothrow()
      .quiet();
    done++;

    if (res.exitCode !== 0) {
      console.error(chalk.red(`  ${String(done).padStart(3)}/${jobs.length}  error  ${j.order.key}`));
      continue;
    }
    let d;
    try { d = JSON.parse(res.stdout); } catch { console.error(chalk.red(`  bad envelope ${j.order.key}`)); continue; }
    cost += d.total_cost_usd ?? 0;

    const parsed = extractLast(d.result ?? '') ?? {judgment: 'unclear', confidence: 'low', note: 'unparseable'};
    const verdict = {
      key: j.order.key,
      url: j.order.url,
      link: 'conventions',
      cap: 'needs-changes',
      categories: j.categories,
      agentsMd: j.agents,
      ...parsed,
      _cost: Number((d.total_cost_usd ?? 0).toFixed(6)),
    };
    results.push(verdict);
    fs.writeFileSync(path.join(OUT_DIR, `${j.order.key}.conventions.json`), JSON.stringify(verdict, null, 1));
    console.log(
      `  ${String(done).padStart(3)}/${jobs.length}  ${MARK[verdict.judgment]}  ${String(verdict.violations?.length ?? 0).padStart(2)} viol  ${j.order.key}`
    );
  }
}

await Promise.all(Array.from({length: Math.min(CONCURRENCY, jobs.length)}, worker));

const tally = (x) => results.filter((r) => r.judgment === x).length;
console.log(chalk.bold('\njudgments'));
for (const x of ['match', 'partial', 'mismatch', 'unclear']) {
  const c = tally(x);
  if (c) console.log(`  ${x.padEnd(10)} ${String(c).padStart(4)}`);
}
console.log(chalk.bold(`\n  cost  $${cost.toFixed(4)}  ($${(cost / Math.max(done, 1)).toFixed(5)}/PR)`));
console.log(chalk.dim(`  -> ${OUT_DIR}`));
