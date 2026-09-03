#!/usr/bin/env zx
// Stage 5c: the duplication link. Two questions, one call:
//
//   1. Does the diff repeat itself?           (answered from the diff alone)
//   2. Does an added helper already exist?    (answered against the local checkout)
//
// The second is the one worth building machinery for, and the search key is the helper's
// own signature. A function named `formatDuration(ms)` tells you where to look: in
// `utils/`, in anything named `*duration*`, and for an existing declaration of the same
// name. The name the author reached for is the name the previous author reached for —
// sentry really does keep `getDuration` in `static/app/utils/duration/getDuration.tsx`.
//
// Capped at `needs-changes`: a duplicated helper is worth a reviewer's glance, never a
// reason to call a PR `bad` on its own.
//
// Usage: zx duplication.mjs [--key 122082] [--population agent-authored] [--limit 25]
//                           [--run] [--concurrency 6]

$.verbose = false;

// direnv prints a banner into stderr for every command run inside a checkout; it would
// otherwise land in the middle of search output.
process.env.DIRENV_LOG_FORMAT = '';

import {scanHelpers, searchPlan} from './detectors.mjs';

const CACHE = (argv.cache ?? path.join(os.homedir(), '.cache/pr-classifier')).replace(
  /^~/,
  os.homedir()
);
const DIFF_DIR = path.join(CACHE, 'diffs');
const OUT_DIR = path.join(CACHE, 'verdicts');
const CODE_ROOT = path.join(os.homedir(), 'code');

const MODEL = argv.model ?? 'haiku';
const CONCURRENCY = Number(argv.concurrency ?? 6);
const DIFF_CHAR_CAP = 24000;

const MAX_HELPERS = 8; // a PR adding more than this is a module, not a helper
const MAX_HITS_PER_HELPER = 10;
const STALE_AFTER_DAYS = 14;

// ---------------------------------------------------------------- searching

// `rg` rather than `ast-grep`, against the general preference for structural search.
// Two reasons, both specific to this stage: ast-grep needs a separate `--lang` pass per
// extension, and sentry mixes .ts, .tsx and .py in one tree; and what we want is the
// declaration HEADER, which a regex states precisely — `ast-grep` has no standalone
// pattern for "a function declaration named X" without also matching its body.
// Candidates must be in the same language as the helper. A TypeScript helper is not
// duplicated by a Python function that shares a word, and offering one as a lead is worse
// than offering nothing — the first search built this way returned four hits in
// `src/sentry/tasks/seer/explorer_index.py` for a `.tsx` helper.
const LANG_GLOBS = {
  js: ['*.ts', '*.tsx', '*.js', '*.jsx'],
  py: ['*.py'],
};

const langOf = (file) => (/\.py$/.test(file) ? 'py' : 'js');

// Test files hold fixtures and local scaffolding, not utilities anyone should reuse.
const NOT_TESTS = ['-g', '!**/*.spec.*', '-g', '!**/*.test.*', '-g', '!**/tests/**', '-g', '!**/test_*.py', '-g', '!**/*_test.py'];

const globsFor = (file) => LANG_GLOBS[langOf(file)].flatMap((g) => ['-g', g]);

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** A declaration of `name`, in any of the shapes the scanner recognises. */
const declRe = (name) =>
  `(?:export\\s+)?(?:async\\s+)?(?:function|def)\\s+${esc(name)}\\b` +
  `|(?:export\\s+)?(?:const|let|var)\\s+${esc(name)}\\s*[:=]`;

/** Any declaration whose name contains `term`. Used to sweep util-ish folders. */
const termRe = (term) =>
  `(?:function|def)\\s+\\w*${esc(term)}\\w*\\s*\\(` +
  `|(?:const|let|var)\\s+\\w*${esc(term)}\\w*\\s*=\\s*(?:async\\s*)?[({]`;

async function rgSearch(root, pattern, globs, extraArgs = []) {
  const res = await $`rg --no-heading --line-number --ignore-case --max-count 4 ${globs} ${NOT_TESTS} ${extraArgs} -e ${pattern} ${root}`
    .nothrow()
    .quiet();
  if (res.exitCode !== 0) return []; // exit 1 simply means no matches
  return res.stdout
    .split('\n')
    .filter(Boolean)
    .map((l) => {
      const m = l.match(/^(.+?):(\d+):(.*)$/);
      if (!m) return null;
      return {file: path.relative(root, m[1]), line: Number(m[2]), text: m[3].trim().slice(0, 200)};
    })
    .filter(Boolean);
}

/**
 * Find existing declarations that a newly added helper may duplicate.
 *
 * Two sweeps, most selective first. An exact name match is near-proof; a same-word helper
 * sitting in a utils folder is a lead worth showing a model.
 */
// Where utils conventionally live. Used to RANK, not to filter: ripgrep ORs its inclusive
// globs, so passing these as `-g` alongside the language globs widens the search instead
// of narrowing it — the first version of this returned Python hits for a .tsx helper.
const UTIL_DIR = /(^|\/)(utils?|helpers?|lib|common|shared)(\/|$)/i;

/** How likely is this hit to be the helper the author should have reused? */
function score(hit, plan) {
  const p = hit.file.toLowerCase();
  let s = 0;
  if (UTIL_DIR.test(hit.file)) s += 2;
  // The helper's own words pointing at a path is the signal the whole stage is built on:
  // `getDuration` really does live in `utils/duration/getDuration.tsx`.
  for (const w of plan.pathWords) if (p.includes(w)) s += 2;
  for (const t of plan.terms) if (hit.text.toLowerCase().includes(t)) s += 1;
  return s;
}

async function findCandidates(root, plan, ownPaths, helperFile) {
  const own = new Set(ownPaths);
  const seen = new Set();
  const globs = globsFor(helperFile);
  const pool = [];

  const collect = (rows, how) => {
    for (const r of rows) {
      if (own.has(r.file) || seen.has(`${r.file}:${r.line}`)) continue;
      seen.add(`${r.file}:${r.line}`);
      pool.push({...r, how});
    }
  };

  // An existing declaration of the same name is near-proof, and is never ranked away.
  const exact = await rgSearch(root, declRe(plan.exactName), globs);
  collect(exact, 'same-name');
  const sameName = pool.slice(0, MAX_HITS_PER_HELPER);
  if (sameName.length >= MAX_HITS_PER_HELPER) return sameName;

  const before = pool.length;
  for (const term of plan.terms.slice(0, 3)) {
    collect(await rgSearch(root, termRe(term), globs), `word:${term}`);
  }

  // Rank the word matches; keep only those with a real reason to be shown.
  const ranked = pool
    .slice(before)
    .map((h) => ({...h, score: score(h, plan)}))
    .filter((h) => h.score > 0)
    .sort((a, b) => b.score - a.score);

  return [...sameName, ...ranked].slice(0, MAX_HITS_PER_HELPER);
}

/** How old is this checkout? A stale clone yields stale leads, and should say so. */
async function checkoutAge(root) {
  const res = await $`git -C ${root} log -1 --format=%cI`.nothrow().quiet();
  if (res.exitCode !== 0) return null;
  const at = new Date(res.stdout.trim());
  return {at: res.stdout.trim(), days: Math.round((Date.now() - at) / 86400000)};
}

// ---------------------------------------------------------------- prompt

const SYSTEM = `You check one thing: does this change duplicate logic that already exists?

Two separate questions. Answer both.

1. INTERNAL — does the diff repeat itself? Two added blocks that do the same work with
   different names, a helper added next to an inline copy of the same logic, the same
   branch written twice. Judge only added lines.

2. EXISTING — does a helper the diff adds already exist in the codebase? You are given
   candidate declarations found by searching for the helper's own name and words. Each
   candidate shows a file, a line and the declaration text.

A candidate is only a duplicate if it does the SAME WORK. Sharing a name prefix is not
enough, and neither is sharing a folder. Say so plainly when candidates are unrelated —
that is the common case, and a false duplicate wastes more of a reviewer's time than it
saves.

You are shown a declaration line, not a function body. If you cannot tell what a candidate
does from its name and signature, that is "unclear" for that helper, never a duplicate.

The candidates come from a local checkout that may be behind the PR's branch. A helper the
diff adds will not usually appear there; if an identical name DOES appear, that is a strong
signal, not an artifact.

Your entire response must be ONE JSON object. Nothing before it, nothing after it.

{
  "judgment": "match" | "partial" | "mismatch" | "unclear",
  "confidence": "low" | "medium" | "high",
  "internal": [{"what": "", "where": ""}],
  "duplicates": [{"added": "", "existing": "", "why": ""}],
  "note": ""
}

judgment:
  match      no duplication — the added logic is new, and the candidates are unrelated
  partial    overlapping logic that a reviewer should look at, or near-duplication
  mismatch   a clear duplicate: the added helper does the same work as an existing one
  unclear    too little to judge — no helpers added, or nothing legible to compare

internal:   repetition inside the diff. "what" names the repeated logic, "where" the files.
duplicates: an added helper that already exists. "existing" must be one of the candidate
            file:line values you were given — never a path you invented.
note:       one sentence, at most 160 characters.

Empty arrays are correct and common. Most changes duplicate nothing.`;

function buildUser(order, diff, helpers, hitsByHelper, age) {
  const blocks = helpers.map((h) => {
    const hits = hitsByHelper.get(h.name) ?? [];
    const lines = hits.length
      ? hits.map((c) => `  [${c.how}] ${c.file}:${c.line}  ${c.text}`).join('\n')
      : '  (no candidates found)';
    return `${h.name}(${h.args.join(', ')})  added in ${h.file}\n${lines}`;
  });

  return `<added_helpers_and_candidates>
${blocks.join('\n\n') || '(no helpers added)'}
</added_helpers_and_candidates>

<checkout>
${age ? `local clone last commit ${age.at} (${age.days} days old)` : 'local clone unavailable'}
</checkout>

<changed_files>
${order.paths.join('\n')}
</changed_files>

<diff>
${diff.slice(0, DIFF_CHAR_CAP)}
</diff>`;
}

// ---------------------------------------------------------------- inputs

const orders = JSON.parse(fs.readFileSync(path.join(CACHE, 'workorders.json'), 'utf8')).orders;

let pool = orders.filter(
  (o) =>
    !o.skip &&
    o.links.some((l) => l.link === 'duplication') &&
    fs.existsSync(path.join(DIFF_DIR, `${o.key}.diff`))
);
if (argv.population) pool = pool.filter((o) => o.population === argv.population);
if (argv.key) pool = pool.filter((o) => o.key.includes(String(argv.key)));
const selected = pool.slice(0, Number(argv.limit ?? 25));

if (!selected.length) {
  console.error(chalk.red('nothing to check. Warm diffs first, and check the PR has code files.'));
  process.exit(1);
}

// ---------------------------------------------------------------- deterministic pass

console.log(chalk.bold(`\nduplication  ${selected.length} PRs  searching local checkouts\n`));

const jobs = [];
for (const order of selected) {
  const diff = fs.readFileSync(path.join(DIFF_DIR, `${order.key}.diff`), 'utf8');
  const repo = order.key.split('__')[1];
  const root = path.join(CODE_ROOT, repo);
  const helpers = scanHelpers(diff).slice(0, MAX_HELPERS);

  const hitsByHelper = new Map();
  let age = null;
  let searched = 'skipped-no-checkout';

  if (fs.existsSync(path.join(root, '.git'))) {
    age = await checkoutAge(root);
    searched = 'searched';
    for (const h of helpers) {
      hitsByHelper.set(h.name, await findCandidates(root, searchPlan(h), order.paths, h.file));
    }
  }

  const totalHits = [...hitsByHelper.values()].reduce((a, b) => a + b.length, 0);
  jobs.push({order, diff, helpers, hitsByHelper, age, searched, totalHits});
  console.log(
    `  ${order.key.padEnd(34)} ${String(helpers.length).padStart(2)} helpers  ` +
      `${String(totalHits).padStart(3)} candidates  ${chalk.dim(searched)}` +
      (age && age.days > STALE_AFTER_DAYS ? chalk.yellow(`  clone ${age.days}d old`) : '')
  );
}

// ---------------------------------------------------------------- dry run

if (!argv.run) {
  console.log(chalk.bold('\nduplication  dry run'));
  for (const j of jobs) {
    for (const h of j.helpers) {
      const hits = j.hitsByHelper.get(h.name) ?? [];
      console.log(`  ${h.name}(${h.args.join(', ')})`);
      for (const c of hits.slice(0, 5)) {
        console.log(chalk.dim(`      [${c.how}] ${c.file}:${c.line}`));
      }
      if (!hits.length) console.log(chalk.dim('      no candidates'));
    }
  }
  console.log(chalk.dim('\n  add --run to execute'));
  process.exit(0);
}

// ---------------------------------------------------------------- run

function extractLast(text) {
  const found = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== '{') continue;
    let depth = 0,
      inStr = false,
      esc2 = false;
    for (let j = i; j < text.length; j++) {
      const c = text[j];
      if (esc2) {
        esc2 = false;
        continue;
      }
      if (c === '\\') {
        esc2 = true;
        continue;
      }
      if (c === '"') {
        inStr = !inStr;
        continue;
      }
      if (inStr) continue;
      if (c === '{') depth++;
      else if (c === '}') {
        depth--;
        if (depth === 0) {
          found.push(text.slice(i, j + 1));
          i = j;
          break;
        }
      }
    }
  }
  for (const c of found.reverse()) {
    try {
      const v = JSON.parse(c);
      if (['match', 'partial', 'mismatch', 'unclear'].includes(v.judgment)) return v;
    } catch {
      /* keep scanning */
    }
  }
  return null;
}

fs.mkdirSync(OUT_DIR, {recursive: true});
console.log(chalk.bold(`\nrunning  model=${MODEL}  concurrency=${CONCURRENCY}\n`));

const MARK = {
  match: chalk.green('none    '),
  partial: chalk.yellow('overlap '),
  mismatch: chalk.red('dup     '),
  unclear: chalk.dim('unclear '),
};

let cost = 0,
  done = 0,
  cursor = 0;
const results = [];

async function worker() {
  while (cursor < jobs.length) {
    const j = jobs[cursor++];
    const user = buildUser(j.order, j.diff, j.helpers, j.hitsByHelper, j.age);
    const res =
      await $({env: {...process.env, MAX_THINKING_TOKENS: '0'}})`claude -p ${user} --model ${MODEL} --system-prompt ${SYSTEM} --output-format json --allowedTools ${''}`
        .nothrow()
        .quiet();
    done++;

    if (res.exitCode !== 0) {
      console.error(chalk.red(`  ${String(done).padStart(3)}/${jobs.length}  error  ${j.order.key}`));
      continue;
    }
    let d;
    try {
      d = JSON.parse(res.stdout);
    } catch {
      console.error(chalk.red(`  bad envelope ${j.order.key}`));
      continue;
    }
    cost += d.total_cost_usd ?? 0;

    const parsed =
      extractLast(d.result ?? '') ?? {judgment: 'unclear', confidence: 'low', note: 'unparseable'};
    const verdict = {
      key: j.order.key,
      url: j.order.url,
      link: 'duplication',
      cap: 'needs-changes',
      helpers: j.helpers.map((h) => ({name: h.name, args: h.args, file: h.file})),
      searched: j.searched,
      checkout: j.age,
      candidates: j.totalHits,
      ...parsed,
      _cost: Number((d.total_cost_usd ?? 0).toFixed(6)),
    };
    results.push(verdict);
    fs.writeFileSync(
      path.join(OUT_DIR, `${j.order.key}.duplication.json`),
      JSON.stringify(verdict, null, 1)
    );
    const counts = `${(verdict.duplicates ?? []).length} dup  ${(verdict.internal ?? []).length} internal`;
    console.log(
      `  ${String(done).padStart(3)}/${jobs.length}  ${MARK[verdict.judgment]}  ${counts}  ${j.order.key}`
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

const flagged = results.filter((r) => (r.duplicates ?? []).length || (r.internal ?? []).length);
if (flagged.length) {
  console.log(chalk.bold('\nfindings'));
  for (const r of flagged) {
    for (const d of r.duplicates ?? []) {
      console.log(`  ${chalk.red('dup')}      ${r.key}  ${d.added} -> ${d.existing}`);
    }
    for (const i of r.internal ?? []) {
      console.log(`  ${chalk.yellow('internal')} ${r.key}  ${i.what}`);
    }
  }
}

const skipped = results.filter((r) => r.searched !== 'searched').length;
if (skipped) {
  console.log(chalk.dim(`\n  ${skipped} PRs had no local checkout — internal duplication only`));
}

console.log(chalk.bold(`\n  cost  $${cost.toFixed(4)}  ($${(cost / Math.max(done, 1)).toFixed(5)}/PR)`));
console.log(chalk.dim(`  -> ${OUT_DIR}`));
