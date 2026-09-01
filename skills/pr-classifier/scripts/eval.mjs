#!/usr/bin/env zx
// Score stage 3 against the gold labels. Prints a confusion matrix and the two numbers
// that actually matter: how many flags survive a careful look, and how many real problems
// were missed.
//
// The gold labels come from a stronger model, not a human (see label.mjs). So this
// measures agreement with a careful pass, not truth. It cannot see an error both passes
// share. Small samples give wide intervals — the Wilson bounds below are printed for that
// reason, not for decoration.
//
// Usage: zx eval.mjs [--cache ~/.cache/pr-classifier] [--verbose]

$.verbose = false;

const CACHE = (argv.cache ?? path.join(os.homedir(), '.cache/pr-classifier')).replace(
  /^~/,
  os.homedir()
);
const GOLD = path.join(CACHE, 'gold.jsonl');

if (!fs.existsSync(GOLD)) {
  console.error(chalk.red('no gold labels — run label.mjs first'));
  process.exit(1);
}

// Join gold against the CURRENT verdicts, not the stage3 value frozen into gold.jsonl at
// labelling time. Otherwise a prompt change cannot be re-measured without relabelling.
const live = new Map();
for (const f of fs.readdirSync(path.join(CACHE, 'verdicts')).filter((f) => f.endsWith('.json'))) {
  const v = JSON.parse(fs.readFileSync(path.join(CACHE, 'verdicts', f), 'utf8'));
  live.set(v.key, v.judgment);
}

const gold = fs
  .readFileSync(GOLD, 'utf8')
  .trim()
  .split('\n')
  .filter(Boolean)
  .map((l) => JSON.parse(l))
  .map((r) => ({...r, stage3: live.get(r.key) ?? r.stage3, stale: !live.has(r.key)}))
  .filter((r) => !r.stale);

const LABELS = ['match', 'partial', 'mismatch', 'unclear'];
const SEV = {match: 0, partial: 1, mismatch: 2, unclear: -1};

/** Wilson score interval — honest about small n, unlike a bare proportion. */
function wilson(hits, total, z = 1.96) {
  if (!total) return [0, 1];
  const p = hits / total;
  const d = 1 + (z * z) / total;
  const c = p + (z * z) / (2 * total);
  const s = z * Math.sqrt((p * (1 - p)) / total + (z * z) / (4 * total * total));
  return [Math.max(0, (c - s) / d), Math.min(1, (c + s) / d)];
}
const pctRange = ([lo, hi]) => `${(lo * 100).toFixed(0)}-${(hi * 100).toFixed(0)}%`;

// ---------------------------------------------------------------- confusion

const cell = (s, g) => gold.filter((r) => r.stage3 === s && r.judgment === g).length;

console.log(chalk.bold(`\neval  n=${gold.length}  (gold = a stronger model, not a human)\n`));

console.log(chalk.bold('confusion   rows = stage 3 (haiku)   cols = gold (opus)'));
console.log(chalk.dim(`  ${''.padEnd(10)}${LABELS.map((l) => l.padStart(9)).join('')}`));
for (const s of LABELS) {
  const row = LABELS.map((g) => {
    const v = cell(s, g);
    if (!v) return chalk.dim('        .');
    return s === g ? chalk.green(String(v).padStart(9)) : chalk.yellow(String(v).padStart(9));
  }).join('');
  const total = LABELS.reduce((a, g) => a + cell(s, g), 0);
  if (total) console.log(`  ${s.padEnd(10)}${row}`);
}

const exact = gold.filter((r) => r.stage3 === r.judgment).length;
console.log(chalk.bold(`\nexact agreement  ${exact}/${gold.length}  ${((exact / gold.length) * 100).toFixed(0)}%  [${pctRange(wilson(exact, gold.length))}]`));

// ---------------------------------------------------------------- flags

// The decision that matters: did stage 3 raise a flag, and should it have?
const isFlag = (j) => j === 'partial' || j === 'mismatch';

const tp = gold.filter((r) => isFlag(r.stage3) && isFlag(r.judgment)).length;
const fp = gold.filter((r) => isFlag(r.stage3) && !isFlag(r.judgment)).length;
const fn = gold.filter((r) => !isFlag(r.stage3) && isFlag(r.judgment)).length;
const tn = gold.filter((r) => !isFlag(r.stage3) && !isFlag(r.judgment)).length;

const prec = tp + fp ? tp / (tp + fp) : 0;
const rec = tp + fn ? tp / (tp + fn) : 0;

console.log(chalk.bold('\nflag / no-flag  (flag = partial or mismatch)'));
console.log(`  true positive  ${String(tp).padStart(3)}   flagged, and gold agrees`);
console.log(`  false positive ${String(fp).padStart(3)}   ${chalk.yellow('flagged, but gold says match')}`);
console.log(`  false negative ${String(fn).padStart(3)}   ${chalk.red('not flagged, but gold found a problem')}`);
console.log(`  true negative  ${String(tn).padStart(3)}   clean, and gold agrees`);
console.log(
  chalk.bold(`\n  precision  ${(prec * 100).toFixed(0)}%  [${pctRange(wilson(tp, tp + fp))}]`) +
    chalk.dim('   of the flags, how many are real')
);
console.log(
  chalk.bold(`  recall     ${(rec * 100).toFixed(0)}%  [${pctRange(wilson(tp, tp + fn))}]`) +
    chalk.dim('   of the real problems, how many were caught')
);

// ---------------------------------------------------------------- direction

const harsher = gold.filter((r) => SEV[r.stage3] > SEV[r.judgment] && SEV[r.judgment] >= 0).length;
const softer = gold.filter((r) => SEV[r.stage3] < SEV[r.judgment] && SEV[r.stage3] >= 0).length;

console.log(chalk.bold('\nbias'));
console.log(`  stage 3 harsher than gold  ${String(harsher).padStart(3)}`);
console.log(`  stage 3 softer  than gold  ${String(softer).padStart(3)}`);
console.log(
  chalk.dim(
    `  ${harsher > softer ? 'over-flagging' : softer > harsher ? 'under-flagging' : 'balanced'} — ` +
      'a false good is the expensive error, a false flag costs one glance'
  )
);

// ---------------------------------------------------------------- disagreements

console.log(chalk.bold('\ndisagreements'));
for (const r of gold.filter((r) => r.stage3 !== r.judgment)) {
  const dir = SEV[r.stage3] > SEV[r.judgment] ? chalk.yellow('harsher') : chalk.red('softer ');
  console.log(`  ${dir}  stage3=${r.stage3.padEnd(8)} gold=${r.judgment.padEnd(8)} ${r.key}`);
  if (argv.verbose) console.log(chalk.dim(`      gold: ${(r.note ?? '').slice(0, 150)}`));
}

console.log(
  chalk.dim(
    `\n  n=${gold.length} is small. Treat the intervals, not the point estimates, as the result.`
  )
);
