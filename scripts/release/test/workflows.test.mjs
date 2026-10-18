import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { parse } from 'yaml';

async function workflow(name) {
  return parse(await readFile(new URL(`../../../.github/workflows/${name}.yml`, import.meta.url), 'utf8'));
}

test('every required PR check is delivered for app, docs, site, and bot PRs without secrets', async () => {
  for (const [file, job, name] of [
    ['app', 'test', 'App tests'],
    ['site', 'test', 'Site tests'],
    ['pr-title', 'title', 'PR title'],
    ['release-tooling', 'contracts', 'Release tooling'],
    ['package-check', 'required', 'Package checks'],
  ]) {
    const value = await workflow(file);
    assert.ok('pull_request' in value.on, file);
    for (const filter of ['paths', 'paths-ignore', 'branches', 'branches-ignore']) {
      assert.equal(value.on.pull_request?.[filter], undefined, `${file}: ${filter}`);
    }
    assert.equal(value.on.pull_request_target, undefined);
    assert.equal(value.jobs[job]?.name, name);
    assert.equal(value.jobs[job]?.if, file === 'package-check' ? '${{ always() }}' : undefined);
    assert.deepEqual(value.permissions, { contents: 'read' });
    assert.doesNotMatch(JSON.stringify(value), /secrets\.|write|github\.actor/);
  }
  const app = await workflow('app');
  assert.ok(app.jobs.test.steps.some(step => step.run?.includes('swift test')));
  const site = await workflow('site');
  assert.equal(site.name, 'Site');
  assert.deepEqual(site.on.push.branches, ['main']);
  assert.deepEqual(site.on.push.paths, ['site/**', '.github/workflows/site.yml']);
  assert.ok(site.jobs.test.steps.some(step => step.run === 'npm test'));
});

test('package required check fails closed when either native build fails, skips, or cancels', async () => {
  const value = await workflow('package-check');
  const gate = value.jobs.required;
  assert.equal(gate.needs, 'installers');
  const step = gate.steps.find(step => step.env?.RESULT);
  assert.equal(step.env.RESULT, '${{ needs.installers.result }}');
  for (const result of ['success', 'failure', 'cancelled', 'skipped', '']) {
    const run = spawnSync('bash', ['-c', step.run], { env: { ...process.env, RESULT: result } });
    assert.equal(run.status === 0, result === 'success', result);
  }
  const packaging = await workflow('package');
  assert.deepEqual(packaging.jobs.package.strategy.matrix.include.map(item => item.arch), ['arm64', 'x86_64']);
  assert.equal(packaging.jobs.package.strategy['fail-fast'], false);
  assert.doesNotMatch(JSON.stringify(packaging), /secrets\.|write/);
});

test('fork PR checks need no credentials, always run, and revalidate edited titles', async () => {
  const title = await workflow('pr-title');
  assert.ok(title.on.pull_request.types.includes('edited'));
  assert.equal(title.on.pull_request.paths, undefined);
  assert.equal(title.on.pull_request_target, undefined);
  assert.deepEqual(title.permissions, { contents: 'read' });
  const step = title.jobs.title.steps.find(step => step.env?.PR_TITLE);
  assert.equal(step.env.PR_TITLE, '${{ github.event.pull_request.title }}');
  assert.equal(step.run, 'node scripts/release/check-title.mjs');
  const tooling = await workflow('release-tooling');
  assert.ok('pull_request' in tooling.on);
  assert.equal(tooling.on.pull_request?.paths, undefined);
  for (const value of [title, tooling]) {
    assert.doesNotMatch(JSON.stringify(value), /secrets\.|write|pull_request_target/);
  }
});

test('trusted main pushes generate PRs using a repository-scoped App token, never publish', async () => {
  const release = await workflow('release-please');
  assert.deepEqual(release.on.push.branches, ['main']);
  assert.equal(release.on.push.paths, undefined);
  assert.equal(release.on.pull_request, undefined);
  assert.deepEqual(release.permissions, { contents: 'read' });
  assert.equal(release.concurrency['cancel-in-progress'], false);
  const steps = release.jobs['release-pr'].steps;
  const token = steps.find(step => step.uses?.startsWith('actions/create-github-app-token@'));
  assert.equal(token.with.repositories, '${{ github.event.repository.name }}');
  assert.equal(token.with['permission-contents'], 'write');
  assert.equal(token.with['permission-pull-requests'], 'write');
  assert.equal(token.with['permission-issues'], 'write');
  const command = steps.find(step => step.env?.GH_TOKEN);
  assert.equal(command.env.GH_TOKEN, '${{ steps.app-token.outputs.token }}');
  assert.match(command.run, /release-please release-pr/);
  assert.match(command.run, /--target-branch main/);
  assert.doesNotMatch(command.run, /github-release|gh release|git tag/);
  assert.ok(steps.some(step => step.run === 'npm ci --ignore-scripts'));
});
