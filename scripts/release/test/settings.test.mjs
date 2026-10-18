import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { test } from 'node:test';
import { applySettings, plan } from '../repository-settings.mjs';

test('settings CLI defaults to a non-mutating plan for protected solo-maintainer squash merges', () => {
  const plan = JSON.parse(execFileSync(process.execPath,
    [new URL('../repository-settings.mjs', import.meta.url).pathname], { encoding: 'utf8' }));
  assert.deepEqual(plan.repository, {
    allow_squash_merge: true, allow_merge_commit: false, allow_rebase_merge: false,
    squash_merge_commit_title: 'PR_TITLE', squash_merge_commit_message: 'BLANK',
  });
  assert.equal(plan.protection.enforce_admins, true);
  assert.equal(plan.protection.required_pull_request_reviews.required_approving_review_count, 0);
  assert.equal(plan.protection.required_pull_request_reviews.require_code_owner_reviews, false);
  assert.equal(plan.protection.allow_force_pushes, false);
  assert.equal(plan.protection.allow_deletions, false);
  assert.equal(plan.protection.required_linear_history, true);
  assert.equal(plan.protection.required_status_checks.strict, true);
  assert.deepEqual(plan.protection.required_status_checks.contexts, []);
  assert.deepEqual(plan.protection.required_status_checks.checks.map(check => check.context),
    ['App tests', 'Site tests', 'PR title', 'Release tooling', 'Package checks']);
  assert.ok(plan.protection.required_status_checks.checks.every(check => check.app_id === 15368));
});

function remote({ protectionError, missingBranch = false, conclusion = 'success', mergeFailure = false } = {}) {
  const writes = [];
  const api = (method, path, body) => {
    if (method !== 'GET') { writes.push({ method, path, body }); return {}; }
    if (path.endsWith('/protection')) {
      if (protectionError) throw protectionError;
      return {};
    }
    if (path.includes('/pulls/')) return {
      state: 'open', base: { ref: 'main' }, merge_commit_sha: 'merge',
      head: { ref: 'impl/checks', sha: 'head', repo: { full_name: 'owner/vishot' } },
    };
    if (path.includes('/branches/')) {
      if (missingBranch) throw new Error('branch missing');
      return { commit: { sha: 'head' } };
    }
    if (path.includes('/check-runs')) return {
      check_runs: ['App tests', 'Site tests', 'PR title', 'Release tooling', 'Package checks']
        .map((name, id) => ({ id: path.includes('/merge/') ? id : id + 100, name,
          app: { id: 15368 }, status: 'completed',
          conclusion: mergeFailure && path.includes('/merge/') ? 'failure' : conclusion })),
    };
    return { permissions: { admin: true }, default_branch: 'main' };
  };
  return { api, writes };
}

test('settings apply refuses plan restrictions, absent remote branches, and unsuccessful checks before writes', () => {
  const forbidden = Object.assign(new Error('Upgrade to GitHub Pro (HTTP 403)'), {
    stderr: 'Upgrade to GitHub Pro (HTTP 403)',
  });
  for (const scenario of [{ protectionError: forbidden }, { missingBranch: true }, { conclusion: 'failure' }, { conclusion: 'skipped' }]) {
    const { api, writes } = remote(scenario);
    assert.throws(() => applySettings('owner/vishot', '12', 'head', api));
    assert.deepEqual(writes, []);
  }
});

test('a failing test-merge check cannot be masked by a newer successful head check', () => {
  const { api, writes } = remote({ mergeFailure: true });
  assert.throws(() => applySettings('owner/vishot', '12', 'head', api), /completed successful/);
  assert.deepEqual(writes, []);
});

test('settings apply configures the documented payload only after a remote checked PR exists', () => {
  const notConfigured = Object.assign(new Error('Not Found'), { stderr: '(HTTP 404)' });
  const { api, writes } = remote({ protectionError: notConfigured });
  applySettings('owner/vishot', '12', 'head', api);
  assert.deepEqual(writes, [
    { method: 'PUT', path: 'repos/owner/vishot/branches/main/protection', body: plan.protection },
    { method: 'PATCH', path: 'repos/owner/vishot', body: plan.repository },
  ]);
});
