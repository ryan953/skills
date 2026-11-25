// Pull Linear IDs and PR references out of free text, branch names and URLs.

export const DEFAULT_REPO = process.env.TASKBOARD_DEFAULT_REPO ?? 'getsentry/sentry';

// Bare `#123` refs are ambiguous across repos. Sentry PR numbers are six digits,
// so shorter bare numbers are far more likely to be another repo or an issue.
const BARE_MIN_DIGITS = 6;

export function prKey(repo, number) {
  return `${repo.toLowerCase()}#${Number(number)}`;
}

export function linearRefs(text, teams) {
  if (!text || !teams.size) return [];
  const alt = [...teams].map(t => t.replace(/[^A-Za-z0-9]/g, '')).join('|');
  // Case-insensitive so branch names like `ryan953/vdy-426-back-nav` match.
  const re = new RegExp(`(?<![A-Za-z0-9])(${alt})-(\\d{1,6})(?![0-9])`, 'gi');
  const out = new Set();
  for (const m of text.matchAll(re)) out.add(`${m[1].toUpperCase()}-${Number(m[2])}`);
  return [...out];
}

export function prRefs(text) {
  if (!text) return [];
  const out = new Set();
  const consumed = [];
  const urlRe = /github\.com\/([\w.-]+\/[\w.-]+)\/pull\/(\d+)/gi;
  const qualRe = /(?<![\w/.-])([\w.-]+\/[\w.-]+)#(\d+)\b/g;
  for (const re of [urlRe, qualRe]) {
    for (const m of text.matchAll(re)) {
      out.add(prKey(m[1], m[2]));
      consumed.push([m.index, m.index + m[0].length]);
    }
  }
  for (const m of text.matchAll(/(?<![\w/#-])#(\d+)\b/g)) {
    if (consumed.some(([a, b]) => m.index >= a && m.index < b)) continue;
    if (m[1].length < BARE_MIN_DIGITS) continue;
    out.add(prKey(DEFAULT_REPO, m[1]));
  }
  return [...out];
}

// Refs in reading order; the first one is usually what the text is about.
export function orderedRefs(text, teams) {
  if (!text) return [];
  const hits = [];
  for (const k of linearRefs(text, teams)) {
    const m = new RegExp(`(?<![A-Za-z0-9])${k.replace('-', '-0*')}(?![0-9])`, 'i').exec(text);
    if (m) hits.push([m.index, k]);
  }
  for (const k of prRefs(text)) {
    const num = k.split('#')[1];
    const m = new RegExp(`[#/]${num}\\b`).exec(text);
    if (m) hits.push([m.index, k]);
  }
  return [...new Set(hits.sort((a, b) => a[0] - b[0]).map(h => h[1]))];
}

// Only closing-keyword lines count: PR bodies also cite related tickets as context
// ("VDY-380 needs a follow-up"), which must not merge two tasks.
const CLOSING_LINE = /^[\s>*-]*(?:fix(?:e[sd])?|close[sd]?|resolve[sd]?|refs?|part of)\b[:\s]/i;
export function closingRefs(body, teams) {
  if (!body) return [];
  return [...new Set(body.split('\n').filter(l => CLOSING_LINE.test(l)).flatMap(l => linearRefs(l, teams)))];
}
