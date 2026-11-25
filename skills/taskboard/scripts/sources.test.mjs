import assert from 'node:assert/strict';
import {mkdirSync, mkdtempSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

import {localSessionId} from './lib/sources.mjs';

test('localSessionId finds the app session that holds a CLI session id, in any account folder', () => {
  const root = mkdtempSync(join(tmpdir(), 'taskboard-sessions-'));
  const org = join(root, 'account', 'org');
  mkdirSync(org, {recursive: true});
  writeFileSync(join(org, 'local_aaa.json'), JSON.stringify({sessionId: 'local_aaa', cliSessionId: 'cli-1'}));
  writeFileSync(join(org, 'local_bbb.json'), JSON.stringify({sessionId: 'local_bbb', cliSessionId: 'cli-2'}));
  writeFileSync(join(org, 'local_bad.json'), '{not json');

  assert.equal(localSessionId('cli-2', root), 'local_bbb');
  assert.equal(localSessionId('cli-missing', root), null);
});
