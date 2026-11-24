#!/usr/bin/env node
// taskboard: one ledger that links Linear issues, PRs, jr conversations and Claude sessions into tasks.
//
//   taskboard.mjs sync [--json] [--offline]     fetch, link, save the ledger, print the report
//   taskboard.mjs ingest jr <file|-> [--archived]  save jr searchConversations output
//   taskboard.mjs show [--json] [--all]          print the saved ledger without fetching
//   --board (sync or show)                       print a compact summary for the taskboard mod
//   taskboard.mjs task <id|item-key>             print one task with its items, as JSON
//   taskboard.mjs join <keyA> <keyB> | split <key> | ignore <key>   manual link fixes
//   taskboard.mjs dispatch <id> [--brief full|review|validate] [--route session|jr|new] [--step <text>]
//   taskboard.mjs assign <id> <item-key> [--notes <text>]   record who works the task

import {existsSync, mkdirSync, readFileSync, renameSync, writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';

import {dispatch} from './lib/dispatch.mjs';
import {link, STAGE_ORDER} from './lib/link.mjs';
import {
  fetchGithub,
  fetchLinear,
  linearTeams,
  normalizeJr,
  readClaudeSessions,
  resolveLinear,
  resolvePrs,
} from './lib/sources.mjs';

const DIR = process.env.TASKBOARD_DIR ?? join(homedir(), '.local', 'state', 'taskboard');
const paths = {
  ledger: join(DIR, 'ledger.json'),
  overrides: join(DIR, 'overrides.json'),
  jr: join(DIR, 'sources', 'jr.json'),
  cache: join(DIR, 'sources', 'fetched.json'),
};

const readJson = (p, fallback) => (existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : fallback);
function writeJson(p, value) {
  mkdirSync(join(p, '..'), {recursive: true});
  // Write then rename so a reader (the mod's timer, a second sync) never sees half a file.
  writeFileSync(`${p}.tmp`, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(`${p}.tmp`, p);
}
const readStdinOrFile = f => readFileSync(f === '-' ? 0 : f, 'utf8');

const VALUE_FLAGS = new Set(['--brief', '--route', '--step', '--notes']);
const [cmd = 'show', ...rest] = process.argv.slice(2);
const flags = new Set();
const opts = {};
const args = [];
for (let i = 0; i < rest.length; i++) {
  const a = rest[i];
  if (VALUE_FLAGS.has(a)) opts[a.slice(2)] = rest[++i];
  else if (a.startsWith('--')) flags.add(a);
  else args.push(a);
}

async function collect() {
  const teams = new Set(process.env.TASKBOARD_LINEAR_TEAMS?.split(',') ?? (await linearTeams()));
  const [{me, items: prs}, linear] = await Promise.all([fetchGithub(teams), fetchLinear()]);
  const claude = readClaudeSessions(teams);
  const jr = readJr(teams);

  // Resolve strong refs to items we did not fetch (merged PRs, tickets assigned to others),
  // so a session whose PR merged can be recognised as finished.
  let items = [...prs, ...linear, ...claude, ...jr];
  for (let pass = 0; pass < 2; pass++) {
    const have = new Set(items.map(i => i.key));
    const wantPrs = new Set();
    const wantLinear = new Set();
    for (const i of items) {
      // The first weak ref is the item's likely subject, so it is resolved too.
      for (const k of [...i.strong, ...i.weak.slice(0, 1)]) {
        if (have.has(k)) continue;
        (k.includes('#') ? wantPrs : wantLinear).add(k);
      }
    }
    if (!wantPrs.size && !wantLinear.size) break;
    const [morePrs, moreLinear] = await Promise.all([resolvePrs([...wantPrs], me, teams), resolveLinear([...wantLinear])]);
    items = [...items, ...morePrs, ...moreLinear];
  }
  // jr is re-read from its snapshot on every build, so an ingest shows up in `sync --offline`.
  return {me, teams: [...teams], items: items.filter(i => i.type !== 'jr'), fetchedAt: new Date().toISOString()};
}

function readJr(teams) {
  const snap = readJson(paths.jr, {active: [], archived: []});
  const active = new Set(snap.active.map(c => c.conversationId));
  return [
    ...normalizeJr(snap.active, teams),
    ...normalizeJr(snap.archived.filter(c => !active.has(c.conversationId)), teams, {archived: true}),
  ];
}

function buildLedger(fetched) {
  const previous = readJson(paths.ledger, null);
  const overrides = readJson(paths.overrides, {});
  const all = [...fetched.items, ...readJr(new Set(fetched.teams))];
  const result = link(all, {previous, overrides});
  const items = Object.fromEntries(all.map(i => [i.key, i]));
  return {version: 1, generatedAt: fetched.fetchedAt, me: fetched.me, ...result, items};
}

// ---------- report ----------

const short = (s, n) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);

function itemLabel(i) {
  if (!i) return '?';
  if (i.type === 'pr') return `${i.meta.repo === 'getsentry/sentry' ? '' : i.meta.repo}#${i.meta.number} ${i.status}`;
  if (i.type === 'linear') return `${i.key} ${i.status}`;
  if (i.type === 'jr') return `jr:${i.status}`;
  return `cc:${i.status}`;
}

function report(ledger, {all = false} = {}) {
  const {tasks, items, queue, changes} = ledger;
  const lines = [];
  const actions = tasks.flatMap(t => t.actions.map(a => ({...a, task: t.id})));
  const count = t => actions.filter(a => a.type === t).length;
  lines.push(
    `taskboard ${ledger.generatedAt}: ${tasks.filter(t => t.stage !== 'done').length} open tasks, ` +
      `${count('needs-you')} need you, ${count('archive')} to archive, ${count('close-linear')} tickets to close, ` +
      `${queue.length} in the review queue, ${ledger.backlog.length} unlinked tickets you filed`
  );

  if (changes.length) {
    lines.push('', 'Changes since last sync:');
    for (const c of changes) lines.push(`  ${c.type.padEnd(8)} ${c.task ?? c.item}  ${c.detail}`);
  }

  for (const stage of STAGE_ORDER) {
    if (stage === 'done' && !all) continue;
    const ts = tasks.filter(t => t.stage === stage);
    if (!ts.length) continue;
    lines.push('', `## ${stage} (${ts.length})`);
    for (const t of ts) {
      const members = t.items.map(k => items[k]);
      const parts = ['linear', 'pr', 'jr', 'claude'].flatMap(type =>
        members.filter(i => i.type === type && (i.open || type === 'pr' || type === 'linear')).map(itemLabel)
      );
      lines.push(`  ${t.id.padEnd(22)} ${short(t.title, 52).padEnd(52)} ${parts.join(', ')}`);
    }
  }

  if (actions.length) {
    lines.push('', 'Suggested actions:');
    for (const a of actions) {
      const i = items[a.item];
      lines.push(`  ${a.type.padEnd(12)} ${a.item}  "${short(i?.title ?? '', 50)}"  (${a.reason}) [task ${a.task}]`);
    }
  }
  return lines.join('\n');
}

// The mod draws from this, so it holds only what a row shows, not every item's metadata.
function board(ledger) {
  const {tasks, items} = ledger;
  const actions = tasks.flatMap(t => t.actions);
  const count = t => actions.filter(a => a.type === t).length;
  const open = tasks.filter(t => t.stage !== 'done');
  const urlOf = t => {
    const members = t.items.map(k => items[k]);
    const pick = type => members.find(i => i.type === type && i.open && i.url)?.url;
    return items[t.owner]?.url ?? pick('pr') ?? pick('linear') ?? pick('jr') ?? pick('claude') ?? null;
  };
  return {
    generatedAt: ledger.generatedAt,
    counts: {
      open: open.length,
      needsYou: count('needs-you'),
      archive: count('archive'),
      close: count('close-linear'),
      queue: ledger.queue.length,
      backlog: ledger.backlog.length,
    },
    tasks: open.map(t => ({
      id: t.id,
      title: t.title,
      stage: t.stage,
      kind: t.kind,
      owner: t.owner,
      url: urlOf(t),
      parts: ['linear', 'pr', 'jr', 'claude']
        .flatMap(type => t.items.map(k => items[k]).filter(i => i.type === type && (i.open || type === 'pr' || type === 'linear')).map(itemLabel))
        .join(', '),
      actions: t.actions.map(a => ({type: a.type, item: a.item})),
    })),
    changes: ledger.changes,
  };
}

function print(ledger) {
  if (flags.has('--board')) console.log(JSON.stringify(board(ledger)));
  else if (flags.has('--json')) console.log(JSON.stringify(ledger, null, 2));
  else console.log(report(ledger, {all: flags.has('--all')}));
}

// ---------- commands ----------

function findTask(ref) {
  const ledger = readJson(paths.ledger, null);
  if (!ledger) throw new Error('No ledger yet; run sync.');
  const id = ledger.itemTask[ref] ?? ref;
  const task = ledger.tasks.find(t => t.id === id);
  if (!task) throw new Error(`No task for ${ref}`);
  return {ledger, task};
}

async function main() {
  if (cmd === 'sync') {
    const fetched = flags.has('--offline') ? readJson(paths.cache, null) : await collect();
    if (!fetched) throw new Error('No cached fetch; run sync without --offline first.');
    if (!flags.has('--offline')) writeJson(paths.cache, fetched);
    const ledger = buildLedger(fetched);
    writeJson(paths.ledger, ledger);
    print(ledger);
    return;
  }
  if (cmd === 'ingest') {
    const [source, file] = args;
    if (source !== 'jr' || !file) throw new Error('Usage: ingest jr <file|-> [--archived]');
    const raw = JSON.parse(readStdinOrFile(file));
    const list = Array.isArray(raw) ? raw : (raw.conversations ?? []);
    const snap = readJson(paths.jr, {active: [], archived: []});
    // searchConversations returns one status at a time, so each call replaces that half of the snapshot.
    if (flags.has('--archived')) snap.archived = list;
    else {
      const nowActive = new Set(list.map(c => c.conversationId));
      // A conversation that left the active list was archived (from here or elsewhere).
      const dropped = snap.active.filter(c => !nowActive.has(c.conversationId));
      snap.archived = [...dropped, ...snap.archived.filter(c => !nowActive.has(c.conversationId) && !dropped.some(d => d.conversationId === c.conversationId))];
      snap.active = list;
    }
    snap.ingestedAt = new Date().toISOString();
    writeJson(paths.jr, snap);
    console.log(`jr: ${snap.active.length} active, ${snap.archived.length} archived`);
    return;
  }
  if (cmd === 'show') {
    const ledger = readJson(paths.ledger, null);
    if (!ledger) throw new Error('No ledger yet; run sync.');
    print(ledger);
    return;
  }
  if (cmd === 'task') {
    const {ledger, task} = findTask(args[0]);
    console.log(JSON.stringify({...task, items: task.items.map(k => ledger.items[k])}, null, 2));
    return;
  }
  if (cmd === 'dispatch') {
    const {ledger, task} = findTask(args[0]);
    console.log(JSON.stringify(dispatch(task, task.items.map(k => ledger.items[k]), opts), null, 2));
    return;
  }
  if (cmd === 'assign') {
    const {ledger, task} = findTask(args[0]);
    if (!args[1]) throw new Error('Usage: assign <id> <item-key> [--notes <text>]');
    task.owner = args[1];
    if (opts.notes) task.notes = opts.notes;
    writeJson(paths.ledger, ledger);
    console.log(`${task.id}: owner ${task.owner}`);
    return;
  }
  if (['join', 'split', 'ignore'].includes(cmd)) {
    const o = readJson(paths.overrides, {join: [], split: [], ignore: []});
    o[cmd] ??= [];
    if (cmd === 'join') {
      if (args.length !== 2) throw new Error('Usage: join <keyA> <keyB>');
      o.join.push(args);
    } else {
      if (!args[0]) throw new Error(`Usage: ${cmd} <key>`);
      o[cmd].push(args[0]);
    }
    writeJson(paths.overrides, o);
    console.log(`Saved. Run "sync --offline" to relink.`);
    return;
  }
  throw new Error(`Unknown command: ${cmd}`);
}

main().catch(err => {
  console.error(err.message);
  process.exit(1);
});
