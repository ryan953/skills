#!/usr/bin/env zx
// Produce gold labels for the description -> code link.
//
// These are NOT human labels. They come from a deliberately stronger pass than stage 3:
// a more capable model, thinking ON, the full diff with no cap, and an instruction to
// verify claim by claim. That measures whether the cheap stage-3 view is good enough —
// it cannot catch an error both passes share. Treat the number as an upper bound on
// agreement, not as ground truth. Anything it flags is worth a human eye.
//
// Sampling is stratified: every PR stage 3 flagged, plus a sample it called `match`,
// so the eval sees false negatives as well as false positives.
//
// Usage: zx label.mjs [--model opus] [--matches 14] [--concurrency 4] [--force]

$.verbose = false;

const CACHE = (argv.cache ?? path.join(os.homedir(), '.cache/pr-classifier')).replace(
  /^~/,
  os.homedir()
);
const DIFF_DIR = path.join(CACHE, 'diffs');
const GOLD = path.join(CACHE, 'gold.jsonl');

const MODEL = argv.model ?? 'opus';
const CONCURRENCY = Number(argv.concurrency ?? 4);
const N_MATCHES = Number(argv.matches ?? 14);
const DIFF_CHAR_CAP = 90000; // far above stage 3's 24000: the careful pass sees more

const SYSTEM = `You are producing a GOLD LABEL for one question, to grade a cheaper classifier.

The question: does the CODE in this diff do what the DESCRIPTION says it does?

You are not reviewing code quality or correctness for its own sake. Judge the fit between
what was promised and what was delivered.

Work claim by claim:
1. List every substantive claim the description makes.
2. For each, find the evidence in the diff, or note that the diff does not show it.
3. Then look for substantive changes the diff makes that the description never mentions.

Be exacting. This label is the reference a cheaper model is measured against, so a sloppy
label corrupts the measurement. Take the time to check each claim properly.

A diff shows changed lines, not whole files. Missing surrounding context is NOT evidence
of a problem. "mismatch" requires positive evidence that the code does something different
from the claim. If you cannot verify a claim either way, that is "unclear".

Ignore renames, formatting, import reordering, lockfiles and test scaffolding.

End your response with ONE JSON object, on its own, after your analysis:

{"judgment": "match|partial|mismatch|unclear", "confidence": "low|medium|high", "note": "<=200 chars"}

match      delivers what it claims, nothing substantive beyond it
partial    delivers some claims but not all, OR makes unmentioned substantive changes
mismatch   does something materially different from what is claimed
unclear    the description is too vague, or the diff too partial, to judge`;

// ---------------------------------------------------------------- sample

const verdicts = fs
  .readdirSync(path.join(CACHE, 'verdicts'))
  .filter((f) => f.endsWith('.json'))
  .map((f) => JSON.parse(fs.readFileSync(path.join(CACHE, 'verdicts', f), 'utf8')));

const flagged = verdicts.filter((v) => v.judgment !== 'match');
const matches = verdicts.filter((v) => v.judgment === 'match').slice(0, N_MATCHES);
const sample = [...flagged, ...matches];

const already = new Set(
  fs.existsSync(GOLD) && !argv.force
    ? fs.readFileSync(GOLD, 'utf8').trim().split('\n').filter(Boolean).map((l) => JSON.parse(l).key)
    : []
);
const todo = sample.filter((v) => !already.has(v.key));

console.log(chalk.bold(`\nlabel  model=${MODEL}  concurrency=${CONCURRENCY}\n`));
console.log(`  stage-3 flagged   ${String(flagged.length).padStart(3)}  (all labelled)`);
console.log(`  stage-3 match     ${String(matches.length).padStart(3)}  (sampled, for false negatives)`);
console.log(`  already labelled  ${String(already.size).padStart(3)}`);
console.log(`  to label          ${String(todo.length).padStart(3)}\n`);

if (!todo.length) {
  console.log(chalk.dim('  nothing to do (use --force to relabel)'));
  process.exit(0);
}

// ---------------------------------------------------------------- run

function buildUser(key) {
  const pr = JSON.parse(fs.readFileSync(path.join(CACHE, 'prs', `${key}.json`), 'utf8')).pr;
  const diff = fs.readFileSync(path.join(DIFF_DIR, `${key}.diff`), 'utf8');
  return `<pr_title>
${pr.title}
</pr_title>

<pr_description>
${(pr.body ?? '').trim() || '(empty)'}
</pr_description>

<diff>
${diff.slice(0, DIFF_CHAR_CAP)}
</diff>`;
}

function extractLast(text) {
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

const out = fs.createWriteStream(GOLD, {flags: argv.force ? 'w' : 'a'});
let cost = 0;
let done = 0;
let cursor = 0;

// Thinking stays ON here — this is the careful pass, and its cost is the point.
async function worker() {
  while (cursor < todo.length) {
    const v = todo[cursor++];
    const res = await $`claude -p ${buildUser(v.key)} --model ${MODEL} --system-prompt ${SYSTEM} --output-format json --allowedTools ${''}`
      .nothrow()
      .quiet();
    done++;

    if (res.exitCode !== 0) {
      console.error(chalk.red(`  ${String(done).padStart(3)}/${todo.length}  error  ${v.key}`));
      continue;
    }
    let d;
    try {
      d = JSON.parse(res.stdout);
    } catch {
      console.error(chalk.red(`  ${String(done).padStart(3)}/${todo.length}  bad envelope  ${v.key}`));
      continue;
    }
    cost += d.total_cost_usd ?? 0;
    const parsed = extractLast(d.result ?? '');
    if (!parsed) {
      console.error(chalk.red(`  ${String(done).padStart(3)}/${todo.length}  unparseable  ${v.key}`));
      continue;
    }

    out.write(JSON.stringify({key: v.key, stage3: v.judgment, ...parsed}) + '\n');
    const agree = parsed.judgment === v.judgment;
    console.log(
      `  ${String(done).padStart(3)}/${todo.length}  ${agree ? chalk.green('agree ') : chalk.yellow('DIFFER')}  ` +
        `stage3=${v.judgment.padEnd(8)} gold=${parsed.judgment.padEnd(8)} ${v.key}`
    );
  }
}

await Promise.all(Array.from({length: Math.min(CONCURRENCY, todo.length)}, worker));
out.end();

console.log(chalk.bold(`\n  cost  $${cost.toFixed(4)}  ($${(cost / Math.max(done, 1)).toFixed(4)}/PR)`));
console.log(chalk.dim(`  -> ${GOLD}`));
