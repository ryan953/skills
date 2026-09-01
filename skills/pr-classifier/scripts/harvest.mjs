#!/usr/bin/env zx
// Harvest PRs into a local cache: one GraphQL call per PR, skipped when unchanged.
// Usage: zx harvest.mjs [--owner getsentry] [--author ryan953]
//                       [--authored 200] [--reviewed 100]
//                       [--cache ~/.cache/pr-classifier] [--force] [--concurrency 6]
//        zx harvest.mjs --pr <url | owner/repo#N>     # just one PR, always re-fetched

$.verbose = false;

const OWNER = argv.owner ?? 'getsentry';
const AUTHOR = argv.author ?? 'ryan953';
const N_AUTHORED = Number(argv.authored ?? 200);
const N_REVIEWED = Number(argv.reviewed ?? 100);
const CONCURRENCY = Number(argv.concurrency ?? 6);
const FORCE = Boolean(argv.force);
const CACHE = (argv.cache ?? path.join(os.homedir(), '.cache/pr-classifier')).replace(
  /^~/,
  os.homedir()
);

const PR_DIR = path.join(CACHE, 'prs');
const INDEX = path.join(CACHE, 'index.json');

const QUERY = `
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$num){
      number title url state isDraft
      createdAt updatedAt closedAt mergedAt
      baseRefName headRefName
      additions deletions changedFiles
      body
      author{login}
      mergedBy{login}
      labels(first:20){nodes{name}}
      timelineItems(last:10,itemTypes:[CLOSED_EVENT]){
        nodes{... on ClosedEvent{createdAt actor{login}}}
      }
      commits(first:100){totalCount nodes{commit{oid committedDate authoredDate messageHeadline}}}
      comments(first:100){nodes{createdAt author{login} body}}
      reviews(first:50){nodes{createdAt state author{login} body
        comments(first:50){nodes{createdAt path body}}}}
      closingIssuesReferences(first:5){nodes{number title url body}}
      files(first:100){nodes{path additions deletions}}
    }
  }
}`;

const keyOf = (owner, repo, num) => `${owner}__${repo}__${num}`;

/** Accept a GitHub PR URL or `owner/repo#123`. */
function parsePrRef(ref) {
  const url = String(ref).match(/github\.com\/([\w.-]+)\/([\w.-]+)\/pull\/(\d+)/);
  if (url) return {owner: url[1], repo: url[2], number: Number(url[3])};
  const short = String(ref).match(/^([\w.-]+)\/([\w.-]+)[#/](\d+)$/);
  if (short) return {owner: short[1], repo: short[2], number: Number(short[3])};
  return null;
}

/** Run `fn` over `items` with a fixed number of workers. */
async function pool(items, limit, fn) {
  const out = new Array(items.length);
  let cursor = 0;
  const worker = async () => {
    while (cursor < items.length) {
      const i = cursor++;
      out[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({length: Math.min(limit, items.length)}, worker));
  return out;
}

/** Enumerate candidate PRs with `gh search`. Returns a Map keyed by owner__repo__num. */
async function search(found, role, flag, limit) {
  const res =
    await $`gh search prs ${flag} --owner ${OWNER} --state closed --limit ${limit} --json number,repository,title,url,state,updatedAt,createdAt,closedAt,isDraft,commentsCount`.nothrow();

  if (res.exitCode !== 0) {
    console.error(chalk.red(`  search ${role} failed: ${res.stderr.trim().split('\n')[0]}`));
    return 0;
  }

  const rows = JSON.parse(res.stdout || '[]');
  for (const r of rows) {
    const [owner, repo] = r.repository.nameWithOwner.split('/');
    const key = keyOf(owner, repo, r.number);
    const prev = found.get(key);
    if (prev) {
      prev.roles.add(role);
      continue;
    }
    found.set(key, {
      key,
      owner,
      repo,
      number: r.number,
      title: r.title,
      url: r.url,
      updatedAt: r.updatedAt,
      commentsCount: r.commentsCount,
      roles: new Set([role]),
    });
  }
  console.log(`  ${role.padEnd(9)} ${String(rows.length).padStart(4)} PRs`);
  return rows.length;
}

/** Fetch one PR's full record. Returns 'cached' | 'fetched' | 'failed'. */
async function fetchPr(cand) {
  const file = path.join(PR_DIR, `${cand.key}.json`);

  if (!FORCE && fs.existsSync(file)) {
    try {
      const cached = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (cached?.pr?.updatedAt === cand.updatedAt) {
        cand.status = 'cached';
        return cached;
      }
    } catch {
      // Corrupt cache entry: fall through and re-fetch.
    }
  }

  const res =
    await $`gh api graphql -f query=${QUERY} -F owner=${cand.owner} -F repo=${cand.repo} -F num=${cand.number}`.nothrow();

  if (res.exitCode !== 0) {
    cand.status = 'failed';
    cand.error = res.stderr.trim().split('\n')[0].slice(0, 160);
    return null;
  }

  let pr;
  try {
    pr = JSON.parse(res.stdout).data.repository.pullRequest;
  } catch (e) {
    cand.status = 'failed';
    cand.error = `parse: ${e.message}`.slice(0, 160);
    return null;
  }
  if (!pr) {
    cand.status = 'failed';
    cand.error = 'pullRequest was null';
    return null;
  }

  const record = {
    _meta: {
      key: cand.key,
      owner: cand.owner,
      repo: cand.repo,
      roles: [...cand.roles],
      fetchedAt: new Date().toISOString(),
    },
    pr,
  };
  fs.writeFileSync(file, JSON.stringify(record, null, 1));
  cand.status = 'fetched';
  return record;
}

// ---------------------------------------------------------------- main

fs.mkdirSync(PR_DIR, {recursive: true});

const found = new Map();

if (argv.pr) {
  const ref = parsePrRef(argv.pr);
  if (!ref) {
    console.error(chalk.red(`could not parse --pr ${argv.pr}`));
    console.error(chalk.dim('  expected a github PR url, or owner/repo#123'));
    process.exit(1);
  }
  const key = keyOf(ref.owner, ref.repo, ref.number);
  // No updatedAt to compare against, so this always re-fetches. That is what you want
  // when someone hands you one PR to look at.
  found.set(key, {key, ...ref, roles: new Set(['explicit'])});
  console.log(chalk.bold(`\nharvest  single PR  ${ref.owner}/${ref.repo}#${ref.number}\n`));
} else {
  console.log(chalk.bold(`\nharvest  owner=${OWNER}  author=${AUTHOR}  cache=${CACHE}\n`));
  console.log(chalk.dim('searching...'));
  await search(found, 'authored', `--author=${AUTHOR}`, N_AUTHORED);
  await search(found, 'reviewed', `--reviewed-by=${AUTHOR}`, N_REVIEWED);
  await search(found, 'commenter', `--commenter=${AUTHOR}`, N_REVIEWED);
}

const candidates = [...found.values()];
console.log(chalk.dim(`\n${candidates.length} unique PRs. fetching (concurrency ${CONCURRENCY})...`));

let done = 0;
const records = await pool(candidates, CONCURRENCY, async (c) => {
  const rec = await fetchPr(c);
  done++;
  if (done % 25 === 0 || done === candidates.length) {
    process.stdout.write(`\r  ${done}/${candidates.length}`);
  }
  return rec;
});
process.stdout.write('\n');

// Slim index for fast iteration downstream.
const index = candidates.map((c, i) => {
  const pr = records[i]?.pr;
  return {
    key: c.key,
    owner: c.owner,
    repo: c.repo,
    number: c.number,
    title: c.title,
    url: c.url,
    roles: [...c.roles],
    status: c.status,
    error: c.error,
    state: pr?.state,
    merged: Boolean(pr?.mergedAt),
    isDraft: pr?.isDraft,
    createdAt: pr?.createdAt,
    updatedAt: pr?.updatedAt,
    closedAt: pr?.closedAt,
    mergedAt: pr?.mergedAt,
    author: pr?.author?.login,
    commits: pr?.commits?.totalCount ?? 0,
    comments: pr?.comments?.nodes?.length ?? 0,
    reviews: pr?.reviews?.nodes?.length ?? 0,
    changedFiles: pr?.changedFiles ?? 0,
    additions: pr?.additions ?? 0,
    deletions: pr?.deletions ?? 0,
    bodyLength: (pr?.body ?? '').length,
  };
});

if (!argv.pr) {
  fs.writeFileSync(
    INDEX,
    JSON.stringify({generatedAt: new Date().toISOString(), owner: OWNER, author: AUTHOR, prs: index}, null, 1)
  );
}

const tally = (f) => index.filter(f).length;
console.log(chalk.bold('\nharvested'));
console.log(`  fetched  ${tally((p) => p.status === 'fetched')}`);
console.log(`  cached   ${tally((p) => p.status === 'cached')}`);
console.log(`  failed   ${tally((p) => p.status === 'failed')}`);
console.log(`  merged   ${tally((p) => p.merged)}`);
console.log(`  closed   ${tally((p) => !p.merged && p.state === 'CLOSED')}`);
console.log(chalk.dim(`\n  index -> ${INDEX}`));

for (const p of index.filter((p) => p.status === 'failed').slice(0, 5)) {
  console.error(chalk.red(`  ! ${p.key}: ${p.error}`));
}
