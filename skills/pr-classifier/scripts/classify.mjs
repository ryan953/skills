#!/usr/bin/env zx
// Stage 3: the description -> code link. The load-bearing link, ~78% of the corpus.
//
// Emits ORDINAL judgments only, never numbers — see PLAN.md section 10. The orchestrator
// does any arithmetic; the model just judges.
//
// Default is --dry-run: renders the exact prompts and prices the run without calling
// anything. Add --run to actually call the API (needs credentials).
//
// Two backends:
//   cli (default) shells out to `claude -p`. Uses your existing Claude Code auth, so it
//                 needs no API key. MAX_THINKING_TOKENS=0 is essential — thinking is 94%
//                 of output tokens here, costs 11x the latency, and measurably HURT
//                 accuracy on this task.
//   api           the Anthropic SDK. Cheaper per call, but needs credentials.
//
// Usage: zx classify.mjs [--population agent-authored] [--limit 20] [--run]
//                        [--backend cli|api] [--concurrency 6] [--model haiku]

$.verbose = false;

const CACHE = (argv.cache ?? path.join(os.homedir(), '.cache/pr-classifier')).replace(
  /^~/,
  os.homedir()
);
const DIFF_DIR = path.join(CACHE, 'diffs');
const OUT_DIR = path.join(CACHE, 'verdicts');
const PROMPT_DIR = path.join(CACHE, 'prompts');

// Cheap by request: the user asked for cheap models wherever possible.
// Haiku 4.5 takes no `effort` and no adaptive `thinking` — omit both.
const BACKEND = argv.backend ?? 'cli';
const CONCURRENCY = Number(argv.concurrency ?? 6);
const MODEL = argv.model ?? (BACKEND === 'cli' ? 'haiku' : 'claude-haiku-4-5');
const MAX_TOKENS = 400;
const DIFF_CHAR_CAP = 24000;
const PRICE = {input: 1.0, output: 5.0}; // $/MTok, Haiku 4.5

// ---------------------------------------------------------------- prompt

// Stable across every PR, so it caches. Keep volatile content out of it.
const SYSTEM = `You grade one link in a pull-request audit: does the CODE do what the DESCRIPTION says?

You are not reviewing code quality, style, or correctness. Another stage does that.
You judge one thing: whether the diff delivers what the description claims, and whether
it also does things the description never mentions.

Your entire response must be ONE JSON object. Nothing before it, nothing after it.
Do not restate the claims. Do not explain how you decided. Do not use XML tags.
Write the JSON immediately.

{
  "judgment": "match" | "partial" | "mismatch" | "unclear",
  "confidence": "low" | "medium" | "high",
  "unfulfilled": [],
  "unclaimed": [],
  "note": ""
}

judgment:
  match      the diff delivers what the description claims, and nothing substantive beyond it
  partial    it delivers some claims but not all, OR it also makes unmentioned substantive changes
  mismatch   the diff does something materially different from what the description claims
  unclear    the description is too vague to check the diff against

confidence:
  high    the description is specific and the diff is small enough to verify end to end
  medium  mostly verifiable, some judgement needed
  low     you are guessing

Judge what the code DOES, not how well the description explains itself. Loose, vague or
imprecise rationale is NOT a defect. A description that names a slightly different
technique but produces the claimed effect is "match", not "partial". Only the behaviour
the code delivers counts.

unfulfilled: claims the description makes that the diff visibly does NOT deliver.
             Not "I could not verify this" — that is "unclear".
unclaimed:   changes that alter behaviour and that a reviewer would want flagged.
             Ignore renames, formatting, imports, lockfiles, test scaffolding, and any
             refactor that is plainly part of delivering the stated change.
note:        one sentence, at most 160 characters, stating the single most important finding.

A diff shows changed lines, not whole files. You will often not see the surrounding code.
That is normal and is NOT evidence of a problem.

"mismatch" requires POSITIVE evidence: the diff visibly does something different from what
the description claims. If you simply cannot see enough to verify a claim, that is
"unclear" — never "mismatch" and never "unfulfilled".

Do not list a claim as unfulfilled just because the supporting code is outside the diff.

Judge only what you can see. Never invent a file or a symbol that is not in the diff.
Empty arrays are correct and common.`;

// Bot footers add tokens and invite the model to grade boilerplate as a claim.
const FOOTER_BLOCKS = /<!--\s*([\w-]+):start\s*-->[\s\S]*?<!--\s*\1:end\s*-->/g;
const FOOTER_LINES = [
  /^I confirm that Sentry can use, modify, copy.*$/gim,
  /^<sub>Comment `@sentry.*$/gim,
  /^\s*<!--[\s\S]*?-->\s*$/gm,
];

function cleanDescription(body) {
  let out = (body ?? '').replace(FOOTER_BLOCKS, '');
  for (const re of FOOTER_LINES) out = out.replace(re, '');
  return out.replace(/\n{3,}/g, '\n\n').trim();
}

function buildUser(order, pr, diff) {
  const truncated = diff.length > DIFF_CHAR_CAP;
  const body = cleanDescription(pr.body);
  return `<pr_title>
${pr.title}
</pr_title>

<pr_description>
${body || '(empty)'}
</pr_description>

<changed_files>
${order.paths.join('\n')}
</changed_files>

<diff>
${diff.slice(0, DIFF_CHAR_CAP)}${truncated ? '\n\n[diff truncated at 24000 chars]' : ''}
</diff>`;
}

// ---------------------------------------------------------------- io

const orders = JSON.parse(fs.readFileSync(path.join(CACHE, 'workorders.json'), 'utf8')).orders;

const eligible = orders.filter(
  (o) => !o.skip && o.links.some((l) => l.link === 'description->code') &&
    fs.existsSync(path.join(DIFF_DIR, `${o.key}.diff`))
);
let pool = eligible;
if (argv.population) pool = pool.filter((o) => o.population === argv.population);
if (argv.key) pool = pool.filter((o) => o.key.includes(String(argv.key)));
const selected = pool.slice(0, Number(argv.limit ?? 25));

if (!selected.length) {
  console.error(
    chalk.red('nothing to classify. Warm some diffs first:\n') +
      chalk.dim('  zx scripts/triage.mjs --population agent-authored --fetch-diffs --limit 30')
  );
  process.exit(1);
}

fs.mkdirSync(OUT_DIR, {recursive: true});
fs.mkdirSync(PROMPT_DIR, {recursive: true});

// Rough token estimate; only used to price a dry run. ~3.7 chars/token on code+prose.
const est = (s) => Math.ceil(s.length / 3.7);

const jobs = selected.map((o) => {
  const record = JSON.parse(fs.readFileSync(path.join(CACHE, 'prs', `${o.key}.json`), 'utf8'));
  const diff = fs.readFileSync(path.join(DIFF_DIR, `${o.key}.diff`), 'utf8');
  const user = buildUser(o, record.pr, diff);
  return {order: o, user, tokens: est(user)};
});

// ---------------------------------------------------------------- dry run

if (!argv.run) {
  for (const j of jobs) {
    fs.writeFileSync(
      path.join(PROMPT_DIR, `${j.order.key}.txt`),
      `=== SYSTEM ===\n${SYSTEM}\n\n=== USER ===\n${j.user}\n`
    );
  }

  const sysTok = est(SYSTEM);
  const inTok = jobs.reduce((a, j) => a + j.tokens, 0) + sysTok; // system caches after job 1
  const outTok = jobs.length * 150;
  const cost = (inTok / 1e6) * PRICE.input + (outTok / 1e6) * PRICE.output;
  const per = cost / jobs.length;

  console.log(chalk.bold(`\ndry run  ${jobs.length} PRs  model=${MODEL}\n`));
  console.log(`  system prompt      ${String(sysTok).padStart(6)} tok  (cached after the first call)`);
  console.log(`  per-PR input       ${String(Math.round((inTok - sysTok) / jobs.length)).padStart(6)} tok  median`);
  console.log(`  total input        ${String(inTok).padStart(6)} tok`);
  console.log(`  est. output        ${String(outTok).padStart(6)} tok`);
  console.log(chalk.bold(`  est. cost          $${cost.toFixed(4)}   ($${per.toFixed(5)}/PR)`));
  console.log(
    chalk.dim(`\n  full corpus (261 PRs) would cost about $${(per * 261).toFixed(2)}`)
  );
  console.log(chalk.dim(`  prompts written -> ${PROMPT_DIR}`));
  console.log(chalk.dim('\n  add --run to execute (needs ANTHROPIC_API_KEY or `ant auth login`)'));
  process.exit(0);
}

// ---------------------------------------------------------------- backends

/**
 * Pull the verdict out of the reply. With thinking off, the model often writes its
 * reasoning as visible prose before the JSON, so never assume the whole reply is JSON —
 * scan for balanced top-level objects and take the last one that parses.
 */
function extractObjects(text) {
  const found = [];
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== '{') continue;
    let depth = 0;
    let inStr = false;
    let esc = false;
    for (let j = i; j < text.length; j++) {
      const c = text[j];
      if (esc) { esc = false; continue; }
      if (c === '\\') { esc = true; continue; }
      if (c === '"') { inStr = !inStr; continue; }
      if (inStr) continue;
      if (c === '{') depth++;
      else if (c === '}') {
        depth--;
        if (depth === 0) { found.push(text.slice(i, j + 1)); i = j; break; }
      }
    }
  }
  return found;
}

const JUDGMENTS = ['match', 'partial', 'mismatch', 'unclear'];

function parseVerdict(text) {
  const raw = (text ?? '').trim();
  const candidates = extractObjects(raw).reverse(); // last complete object wins
  for (const c of candidates) {
    try {
      const v = JSON.parse(c);
      if (JUDGMENTS.includes(v.judgment)) return v;
    } catch {
      // not this one; keep scanning
    }
  }
  return {
    judgment: 'unclear',
    confidence: 'low',
    note: 'unparseable model output',
    _raw: raw.slice(-400),
  };
}

/** Shell out to `claude -p`. Uses existing Claude Code auth; no API key needed. */
async function viaCli(job) {
  const res = await $({
    env: {...process.env, MAX_THINKING_TOKENS: '0'},
  })`claude -p ${job.user} --model ${MODEL} --system-prompt ${SYSTEM} --output-format json --allowedTools ${''}`
    .nothrow()
    .quiet();

  if (res.exitCode !== 0) return {_error: res.stderr.trim().split('\n')[0].slice(0, 160)};
  try {
    const d = JSON.parse(res.stdout);
    if (d.is_error) return {_error: d.result?.slice(0, 160) ?? 'cli reported is_error'};
    return {text: d.result, cost: d.total_cost_usd ?? 0, usage: d.usage ?? {}, ms: d.duration_api_ms ?? 0};
  } catch (e) {
    return {_error: `unparseable cli envelope: ${e.message}`.slice(0, 160)};
  }
}

/** Direct Anthropic SDK. Cheaper, but needs credentials. */
let apiClient = null;
async function viaApi(job) {
  if (!apiClient) {
    let Anthropic;
    try {
      ({default: Anthropic} = await import('@anthropic-ai/sdk'));
    } catch {
      console.error(
        chalk.red('@anthropic-ai/sdk is not installed.\n') +
          chalk.dim('  cd ~/.claude/skills/pr-classifier && pnpm add @anthropic-ai/sdk')
      );
      process.exit(1);
    }
    apiClient = new Anthropic();
  }
  const res = await apiClient.messages
    .create({
      model: MODEL,
      max_tokens: MAX_TOKENS,
      system: [{type: 'text', text: SYSTEM, cache_control: {type: 'ephemeral'}}],
      messages: [{role: 'user', content: job.user}],
    })
    .catch((e) => ({_error: e.message?.slice(0, 160)}));
  if (res._error) return res;
  const u = res.usage ?? {};
  const cost = ((u.input_tokens ?? 0) / 1e6) * PRICE.input + ((u.output_tokens ?? 0) / 1e6) * PRICE.output;
  return {
    text: res.content.filter((b) => b.type === 'text').map((b) => b.text).join(''),
    cost,
    usage: u,
    ms: 0,
  };
}

const call = BACKEND === 'cli' ? viaCli : viaApi;

// ---------------------------------------------------------------- live run

console.log(chalk.bold(`\nclassify  ${jobs.length} PRs  backend=${BACKEND}  model=${MODEL}  concurrency=${CONCURRENCY}\n`));

const MARK = {
  match: chalk.green('match   '),
  partial: chalk.yellow('partial '),
  mismatch: chalk.red('mismatch'),
  unclear: chalk.dim('unclear '),
};

const results = new Array(jobs.length);
let cost = 0;
let done = 0;
let cursor = 0;

async function worker() {
  while (cursor < jobs.length) {
    const i = cursor++;
    const j = jobs[i];
    const res = await call(j);
    done++;

    if (res._error) {
      console.error(chalk.red(`  ${String(done).padStart(3)}/${jobs.length}  error     ${j.order.key}: ${res._error}`));
      results[i] = {key: j.order.key, link: 'description->code', judgment: 'unclear', error: res._error};
      continue;
    }

    cost += res.cost;
    const verdict = {
      key: j.order.key,
      url: j.order.url,
      population: j.order.population,
      outcome: j.order.outcome,
      link: 'description->code',
      cap: 'bad', // this link may assert the highest severity
      ...parseVerdict(res.text),
      _cost: Number(res.cost.toFixed(6)),
    };
    results[i] = verdict;
    fs.writeFileSync(path.join(OUT_DIR, `${j.order.key}.json`), JSON.stringify(verdict, null, 1));
    console.log(
      `  ${String(done).padStart(3)}/${jobs.length}  ${MARK[verdict.judgment]}  ${verdict.confidence.padEnd(6)}  ${j.order.key}`
    );
  }
}

const started = Date.now();
await Promise.all(Array.from({length: Math.min(CONCURRENCY, jobs.length)}, worker));
const elapsed = (Date.now() - started) / 1000;

fs.writeFileSync(
  path.join(CACHE, 'verdicts.json'),
  JSON.stringify({generatedAt: new Date().toISOString(), backend: BACKEND, model: MODEL, results}, null, 1)
);

const tally = (j) => results.filter((r) => r?.judgment === j).length;
console.log(chalk.bold('\njudgments'));
for (const j of ['match', 'partial', 'mismatch', 'unclear']) {
  const n = tally(j);
  console.log(`  ${j.padEnd(10)} ${String(n).padStart(4)}  ${`${((n / results.length) * 100).toFixed(0)}%`.padStart(4)}`);
}
console.log(chalk.bold('\nrun'));
console.log(`  errors     ${String(results.filter((r) => r?.error).length).padStart(4)}`);
console.log(`  elapsed    ${elapsed.toFixed(1)}s  (${(elapsed / jobs.length).toFixed(1)}s/PR wall)`);
console.log(chalk.bold(`  cost       $${cost.toFixed(4)}  ($${(cost / jobs.length).toFixed(5)}/PR)`));
console.log(chalk.dim(`  261 PRs at this rate: about $${((cost / jobs.length) * 261).toFixed(2)}`));
console.log(chalk.dim(`\n  -> ${OUT_DIR}`));
