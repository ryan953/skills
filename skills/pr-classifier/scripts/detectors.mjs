// The deterministic detectors, kept in one place so `detectors.test.mjs` exercises the
// same code the pipeline runs. Pure string functions, no zx globals — importable from a
// plain `node` process.
//
// Both are things a model reads badly and a regex settles: asked whether an `any` is
// acceptable, a cheap model reasons about pragmatism and waves it through; asked whether
// a body "has a screenshot", it counts vendor badges.

// ---------------------------------------------------------------- explicit `any`

// `any` switches the type checker off for everything downstream of it. Matched in TYPE
// position only, so the prose word "any" and `no-explicit-any` disable comments do not
// register.
const ANY_IN_TYPE_POSITION = [
  /:\s*any\b/, // const x: any / (p: any) =>
  /\bas\s+any\b/, // x as any
  /<\s*any\s*[,>]/, // Foo<any>, Map<any, B>
  /,\s*any\s*>/, // Record<string, any>
  /\bany\[\]/, // any[]
];

const TS_FILE = /\.tsx?$/;

const stripNoise = (line) =>
  line
    .replace(/\/\/.*$/, '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(['"`])(?:\\.|(?!\1).)*\1/g, '""');

// Added TS lines only. A pre-existing `any` is not this PR's finding.
export function scanAnyTypes(diff) {
  const hits = [];
  let file = null;
  for (const line of diff.split('\n')) {
    if (line.startsWith('+++ ')) {
      file = line.slice(4).replace(/^b\//, '').trim();
      continue;
    }
    if (!file || !TS_FILE.test(file)) continue;
    if (!line.startsWith('+') || line.startsWith('+++')) continue;
    const code = stripNoise(line.slice(1));
    if (ANY_IN_TYPE_POSITION.some((re) => re.test(code))) {
      hits.push({file, line: code.trim().slice(0, 120)});
    }
  }
  return hits;
}

// ---------------------------------------------------------------- demo image

const IMAGE_PATTERNS = [
  /!\[[^\]]*\]\([^)]+\)/, // markdown image
  /<img\s[^>]*src=/i,
  /<video[\s>]/i,
  /https?:\/\/[^\s)]+\.(?:png|jpe?g|gif|webp|mp4|mov|webm)/i,
  /https?:\/\/(?:user-images\.githubusercontent\.com|github\.com\/user-attachments\/assets)\/[^\s)]+/i,
];

// Badge rows are images by markup and nothing by content — a shields.io "view review"
// pill, an agent vendor's footer logo. Without this they were 8 of the first 30 hits.
const BADGE_HOST = /img\.shields\.io|badgen\.net|cursor\.(?:com|sh)|codecov\.io|app\.codecov/i;

const dropBadges = (text) =>
  (text ?? '')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, (m) => (BADGE_HOST.test(m) ? '' : m))
    .replace(/<(?:img|source)\s[^>]*>/gi, (m) => (BADGE_HOST.test(m) ? '' : m))
    .replace(/https?:\/\/\S+/g, (m) => (BADGE_HOST.test(m) ? '' : m));

export const hasImage = (text) => IMAGE_PATTERNS.some((re) => re.test(dropBadges(text)));

// Read from the body and from the AUTHOR's own comments. A reviewer pasting a screenshot
// of a bug is not the author demonstrating the change.
export function demoEvidence(pr, authorLogin) {
  const inBody = hasImage(pr.body);
  const inComments = (pr.comments?.nodes ?? []).some(
    (c) => c.author?.login === authorLogin && hasImage(c.body)
  );
  return {hasImage: inBody || inComments, where: inBody ? 'body' : inComments ? 'comment' : null};
}
