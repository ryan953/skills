// Guards the two deterministic detectors. Plain node, no runner: `node scripts/detectors.test.mjs`.
//
// These exist because both regexes were wrong on the first pass against real data — the
// image detector counted 8 vendor badges as screenshots, and the `any` scanner has to
// survive the word "any" appearing in prose, strings and eslint-disable comments.
import assert from 'node:assert';
import {scanAnyTypes, hasImage} from './detectors.mjs';

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

console.log('detectors: all checks passed');
