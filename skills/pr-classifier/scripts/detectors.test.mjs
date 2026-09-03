// Guards the two deterministic detectors. Plain node, no runner: `node scripts/detectors.test.mjs`.
//
// These exist because both regexes were wrong on the first pass against real data — the
// image detector counted 8 vendor badges as screenshots, and the `any` scanner has to
// survive the word "any" appearing in prose, strings and eslint-disable comments.
import assert from 'node:assert';
import {scanAnyTypes, hasImage, scanHelpers, searchPlan, words} from './detectors.mjs';

// ---------------------------------------------------------------- explicit any

const ANY_FORMS = `+++ b/static/app/x.tsx
+const a: any = 1;
+const b = c as any;
+function f(p: any) {}
+let d: any[] = [];
+const e: Record<string, any> = {};
+const g = new Map<any, string>();
`;
assert.equal(scanAnyTypes(ANY_FORMS).length, 6, 'all six any forms');

const NOT_ANY = `+++ b/static/app/y.tsx
+// we do not want any of these
+const msg = 'accepts any value';
+/* any comment */
+const ok: string = 'many any words';
+// eslint-disable-next-line @typescript-eslint/no-explicit-any
+const anyone = 1;
`;
assert.deepEqual(scanAnyTypes(NOT_ANY), [], 'prose, strings and disable comments are not hits');

assert.deepEqual(scanAnyTypes('+++ b/src/thing.py\n+x: any = 1\n'), [], 'only TS is scanned');

assert.deepEqual(
  scanAnyTypes('+++ b/static/app/z.ts\n-const old: any = 1;\n const ctx: any = 2;\n'),
  [],
  'only added lines count'
);

// ---------------------------------------------------------------- demo image

for (const t of [
  '![before](https://example.com/a.png)',
  '<img src="x.png" width=400>',
  '<video src="demo.mp4"></video>',
  'see https://github.com/user-attachments/assets/abc-123',
  'https://user-images.githubusercontent.com/1/x.gif',
  'recording: https://cdn.example.com/clip.mov',
]) {
  assert.ok(hasImage(t), `should detect: ${t}`);
}

for (const t of [
  'no image here',
  'https://github.com/getsentry/sentry/pull/1',
  '',
  null,
  '[![View Interactive Review](https://img.shields.io/badge/Review-html-D97757)](https://x.dev)',
  '<div><a href="https://cursor.com/agents/bc-1"><picture><source srcset="https://cursor.com/x.png"><img src="https://cursor.com/x.png"></picture></a></div>',
]) {
  assert.ok(!hasImage(t), `should NOT detect: ${t}`);
}

assert.ok(
  hasImage(
    '![badge](https://img.shields.io/badge/a-b) and ![real](https://github.com/user-attachments/assets/abc)'
  ),
  'a badge must not mask a real screenshot'
);

// ---------------------------------------------------------------- helper signatures

const named = (diff) => Object.fromEntries(scanHelpers(diff).map((h) => [h.name, h.args]));

// Prettier breaks long signatures, so the arguments are usually not on the naming line.
const MULTILINE = `+++ b/static/app/utils/x.tsx
+export function mergeSpans(
+  spans: Array<Span>,
+  window: Record<string, number>
+): Span[] {
`;
assert.deepEqual(named(MULTILINE), {mergeSpans: ['spans', 'window']}, 'multi-line signature');

// A generic's comma is not an argument separator, and a string default's comma is not one
// either — both split one parameter into fragments if handled naively.
const TRICKY = `+++ b/a/utils/time.ts
+export function formatDuration(ms: number, opts: {short: boolean} = {short: true}) {
+const parseList = (raw: string, sep = ",") => raw.split(sep);
+++ b/a/x.py
+def normalize_url(url, base_url=None):
`;
assert.deepEqual(named(TRICKY), {
  formatDuration: ['ms', 'opts'],
  parseList: ['raw', 'sep'],
  normalize_url: ['url', 'base_url'],
});

// Components are not utils, and a throwaway name carries no search signal.
assert.deepEqual(
  named('+++ b/a/C.tsx\n+export function MyComponent(props: Props) {\n+const fn = (x) => x;\n'),
  {},
  'PascalCase components and generic names are skipped'
);

assert.deepEqual(
  named('+++ b/a/x.ts\n-export function removed(a) {\n export function untouched(b) {\n'),
  {},
  'only added lines count'
);

assert.deepEqual(named('+++ b/a/notes.md\n+function inMarkdown(a) {\n'), {}, 'only code files');

// ---------------------------------------------------------------- search plan

assert.deepEqual(words('getDurationFromHTTPRequest'), [
  'get', 'duration', 'from', 'http', 'request',
]);
assert.deepEqual(words('normalize_url'), ['normalize', 'url']);

const plan = searchPlan({name: 'getDuration', args: ['seconds', 'fixedDigits']});
assert.equal(plan.exactName, 'getDuration');
assert.ok(!plan.terms.includes('get'), 'stop words are dropped — "get" matches the whole repo');
assert.ok(plan.terms.includes('duration'), 'the distinctive word survives');
// This is the claim the whole stage rests on: the helper's own words name the path.
assert.deepEqual(plan.pathWords, ['duration']);

console.log('detectors: all checks passed');
