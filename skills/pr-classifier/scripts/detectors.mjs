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

// ---------------------------------------------------------------- helper signatures

// The duplication link starts from what the PR actually added. A helper's NAME and
// ARGUMENTS are the search key: a function called `formatDuration(ms)` tells you to go
// looking in `utils/`, in anything named `*duration*` or `*format*`, and for an existing
// function of the same arity. That is the whole trick — the name the author reached for
// is the name the previous author reached for too.
// Each pattern captures the NAME and must end at the opening paren of the parameter list —
// the parameters themselves are read by walking brackets, not by a regex, because they
// routinely span lines and contain commas inside generics.
const HELPER_PATTERNS = [
  // export function foo( / async function foo(
  /^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\(/,
  // export const foo = ( / const foo = async (
  /^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+?)?=\s*(?:async\s*)?(?:<[^>]*>)?\s*\(/,
  // export const foo = function (
  /^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?function\s*\(/,
  // python: def foo(
  /^\s*(?:async\s+)?def\s+([A-Za-z_][\w]*)\s*\(/,
];

// React components are not utils. They are PascalCase by convention, and a component that
// happens to share a name with a helper is not a duplicate of it.
const isComponentName = (name) => /^[A-Z]/.test(name);

// Single-letter and throwaway names carry no search signal — `fn(x)` tells you nothing
// about where a similar helper might live, so it would only produce noise.
const TOO_GENERIC = new Set(['fn', 'cb', 'f', 'g', 'x', 'y', 'i', 'it', 'run', 'main', 'inner', 'wrapper']);

const CODE_FILE = /\.(tsx?|jsx?|py)$/;

// A parameter list cannot be split on commas: `Record<string, string>` is one type with a
// comma in it, and splitting naively turns one argument into three fragments of a generic.
// Split on commas at bracket depth zero, then cut each parameter at its first top-level
// colon or equals — what remains is the binding name.
function splitParams(raw) {
  const OPEN = {'<': '>', '(': ')', '[': ']', '{': '}'};
  const CLOSE = new Set(Object.values(OPEN));
  const out = [];
  let depth = 0;
  let cur = '';
  let quote = null; // a default value like `sep = ","` puts a comma inside a string
  for (const ch of raw) {
    if (quote) {
      if (ch === quote) quote = null;
      cur += ch;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') {
      quote = ch;
      cur += ch;
      continue;
    }
    if (OPEN[ch]) depth++;
    else if (CLOSE.has(ch)) depth--;
    if (ch === ',' && depth <= 0) {
      out.push(cur);
      cur = '';
      continue;
    }
    cur += ch;
  }
  out.push(cur);
  return out;
}

function bindingName(param) {
  let depth = 0;
  let name = '';
  for (const ch of param) {
    if (ch === '<' || ch === '(' || ch === '[') depth++;
    else if (ch === '>' || ch === ')' || ch === ']') depth--;
    // A destructured parameter has no single name; keep its keys, they are real words.
    else if ((ch === ':' || ch === '=') && depth <= 0) break;
    name += ch;
  }
  return name;
}

const parseArgs = (raw) =>
  splitParams(raw)
    .map((p) => bindingName(p).replace(/[{}[\].*]/g, ' ').trim())
    .flatMap((a) => a.split(/\s+/))
    .filter(Boolean)
    .filter((a) => a !== 'self' && a !== 'cls');

/**
 * Read a parameter list starting just after its opening paren, continuing across added
 * lines until the brackets balance. Prettier breaks any signature past the line limit,
 * so the arguments — the more selective half of the search key — are frequently not on
 * the line that names the function.
 */
function readParams(lines, startLine, afterMatch) {
  let depth = 1;
  let raw = '';
  for (let j = startLine; j < lines.length && j < startLine + 12; j++) {
    if (!lines[j].startsWith('+')) break;
    const text = j === startLine ? lines[j].slice(1).slice(afterMatch) : lines[j].slice(1);
    for (const ch of text) {
      if (ch === '(') depth++;
      else if (ch === ')') depth--;
      if (depth === 0) return raw;
      raw += ch;
    }
    raw += ' ';
  }
  return raw;
}

/**
 * Helpers added or changed by the diff. Added lines only — a helper the PR merely moved
 * past is not this PR's to answer for.
 */
export function scanHelpers(diff) {
  const found = new Map(); // file:name -> entry, so a helper touched twice counts once
  const lines = diff.split('\n');
  let file = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('+++ ')) {
      file = line.slice(4).replace(/^b\//, '').trim();
      continue;
    }
    if (!file || !CODE_FILE.test(file)) continue;
    if (!line.startsWith('+') || line.startsWith('+++')) continue;

    const code = line.slice(1);
    for (const re of HELPER_PATTERNS) {
      const m = code.match(re);
      if (!m) continue;
      const [, name] = m;
      if (isComponentName(name) || TOO_GENERIC.has(name)) break;

      const key = `${file}:${name}`;
      if (!found.has(key)) {
        found.set(key, {file, name, args: parseArgs(readParams(lines, i, m[0].length))});
      }
      break;
    }
  }
  return [...found.values()];
}

// ---------------------------------------------------------------- where to look

// Split an identifier into its words: camelCase, PascalCase, snake_case, kebab-case.
export const words = (name) =>
  name
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .split(/[\s_-]+/)
    .map((w) => w.toLowerCase())
    .filter(Boolean);

// Words too common to narrow anything down. Searching sentry for "get" returns the repo.
const STOP_WORDS = new Set([
  'get', 'set', 'is', 'has', 'to', 'from', 'the', 'a', 'an', 'of', 'on', 'in', 'for',
  'with', 'and', 'or', 'do', 'make', 'new', 'value', 'data', 'item', 'obj', 'options',
  'props', 'args', 'params', 'result', 'type', 'name', 'id',
]);

/**
 * Turn a helper signature into a search plan: the distinctive words to grep for, and the
 * path fragments most likely to already hold a helper like it.
 *
 * Deliberately produces path *fragments*, not globs — the caller greps a file list, which
 * behaves the same across repos with different layouts.
 */
export function searchPlan({name, args = []}) {
  const nameWords = words(name).filter((w) => !STOP_WORDS.has(w));
  const argWords = args.flatMap(words).filter((w) => !STOP_WORDS.has(w) && w.length > 2);

  return {
    name,
    // An existing function of the same name is the strongest signal there is.
    exactName: name,
    // Distinctive words, longest first: the rarest word is the most selective query.
    terms: [...new Set([...nameWords, ...argWords])].sort((a, b) => b.length - a.length).slice(0, 6),
    // The helper's own words, long enough to mean something in a path. These are what
    // make `getDuration` -> `utils/duration/getDuration.tsx` findable.
    pathWords: nameWords.filter((w) => w.length > 3),
    arity: args.length,
  };
}
