import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const checker = new URL('../check-title.mjs', import.meta.url);

test('contributors can express every supported type, scope, and breaking marker', () => {
  for (const type of ['feat', 'fix', 'docs', 'chore', 'refactor', 'perf', 'test', 'build', 'ci', 'revert']) {
    for (const suffix of ['', '(capture)', '!', '(app/deps)!']) {
      const result = spawnSync(process.execPath, [checker.pathname, `${type}${suffix}: improve capture`]);
      assert.equal(result.status, 0, result.stderr.toString());
    }
  }
});

test('malformed or unsupported titles fail with actionable guidance', () => {
  for (const title of ['', 'Update capture', 'feature: capture', 'Fix: capture', 'fix:capture',
    'fix: ', 'fix(): capture', 'fix: capture ', ' fix: capture', 'fix: capture\nfeat: surprise']) {
    const result = spawnSync(process.execPath, [checker.pathname, title]);
    assert.equal(result.status, 1, title);
    assert.match(result.stderr.toString(), /fix:.*feat\(capture\)!:/);
  }
});
