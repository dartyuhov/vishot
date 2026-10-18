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

test('required release tooling includes real Homebrew validation on every PR', async () => {
  const flow = await workflow('release-tooling');
  assert.equal(flow.jobs.contracts['runs-on'], 'macos-15');
  const step = flow.jobs.contracts.steps.find(step => step.env?.VISHOT_TEST_HOMEBREW);
  assert.equal(step.env.VISHOT_TEST_HOMEBREW, '1');
  assert.equal(step['working-directory'], '${{ github.workspace }}');
  assert.equal(step['continue-on-error'], undefined);
  assert.equal(step.if, undefined);
  const standalone = await workflow('homebrew');
  assert.equal(step.run, standalone.jobs.cask.steps.find(step => step.run?.includes('unittest')).run);
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

test('publication is trusted, serialized, gated by both native packages, and explicitly resumable', async () => {
  const flow = await workflow('publish-release');
  assert.deepEqual(flow.on.push.branches, ['main']);
  assert.equal(flow.on.pull_request, undefined);
  assert.equal(flow.on.pull_request_target, undefined);
  assert.equal(flow.on.workflow_dispatch.inputs.release_pr.required, true);
  assert.deepEqual(flow.permissions, { contents: 'read' });
  assert.equal(flow.concurrency['cancel-in-progress'], false);
  assert.equal(flow.concurrency.group, 'release-publication');
  assert.equal(flow.jobs.approval.if, "github.ref == 'refs/heads/main'");
  assert.equal(flow.jobs.package.uses, './.github/workflows/package.yml');
  assert.equal(flow.jobs.package.with.source_sha, '${{ needs.approval.outputs.source_sha }}');
  assert.equal(flow.jobs.package.with.version, '${{ needs.approval.outputs.version }}');
  assert.equal(flow.jobs.package.secrets, undefined);
  assert.deepEqual(flow.jobs.publish.needs, ['approval', 'package']);
  assert.doesNotMatch(flow.jobs.publish.if ?? '', /always/);
  assert.doesNotMatch(JSON.stringify(flow.jobs.approval), /secrets\./);
  const steps = flow.jobs.publish.steps;
  const token = steps.find(step => step.uses?.startsWith('actions/create-github-app-token@'));
  assert.equal(token.with.repositories, '${{ github.event.repository.name }}');
  assert.equal(token.with['permission-contents'], 'write');
  assert.equal(token.with['permission-issues'], 'write');
  assert.equal(token.with['permission-pull-requests'], 'read');
  const download = steps.find(step => step.uses?.startsWith('actions/download-artifact@'));
  assert.equal(download.with['merge-multiple'], false, 'duplicate files must not be overwritten');
  assert.equal(download.with['run-id'], undefined, 'consume this successful package run only');
  const command = steps.find(step => step.env?.GH_TOKEN);
  assert.equal(command.env.SOURCE_SHA, '${{ needs.approval.outputs.source_sha }}');
  assert.equal(command.env.RELEASE_PR, '${{ needs.approval.outputs.release_pr }}');
  assert.equal(command.env.GH_TOKEN, '${{ steps.publisher.outputs.token }}');
});

test('tap update follows publication directly and recovers independently with tap-only credentials', async () => {
  const publish = await workflow('publish-release');
  const call = publish.jobs['update-tap'];
  assert.deepEqual(call.needs, ['approval', 'publish']);
  assert.equal(call.uses, './.github/workflows/update-tap.yml');
  assert.equal(call.with.tag, 'v${{ needs.approval.outputs.version }}');
  assert.deepEqual(call.secrets, { TAP_APP_PRIVATE_KEY: '${{ secrets.TAP_APP_PRIVATE_KEY }}' });
  const flow = await workflow('update-tap');
  assert.ok(flow.on.workflow_call);
  assert.equal(flow.on.workflow_dispatch.inputs.tag.required, true);
  assert.deepEqual(Object.keys(flow.on).sort(), ['workflow_call', 'workflow_dispatch']);
  assert.deepEqual(flow.permissions, { contents: 'read' });
  assert.equal(flow.concurrency.group, 'homebrew-tap-update');
  assert.equal(flow.concurrency['cancel-in-progress'], false);
  const job = flow.jobs.update;
  assert.equal(job.if, "github.ref == 'refs/heads/main' && github.repository == 'dartyuhov/vishot'");
  const checkout = job.steps.find(step => step.uses?.startsWith('actions/checkout@'));
  assert.equal(checkout.with.ref, 'main');
  assert.equal(checkout.with['persist-credentials'], false);
  const token = job.steps.find(step => step.uses?.startsWith('actions/create-github-app-token@'));
  assert.equal(token.with.owner, 'dartyuhov');
  assert.equal(token.with.repositories, 'homebrew-tap');
  assert.equal(token.with['permission-contents'], 'write');
  assert.deepEqual(Object.keys(token.with).filter(key => key.startsWith('permission-')), ['permission-contents']);
  assert.equal(token.with['private-key'], '${{ secrets.TAP_APP_PRIVATE_KEY }}');
  const command = job.steps.find(step => step.env?.TAP_TOKEN);
  assert.equal(command.env.TAG, '${{ inputs.tag }}');
  assert.equal(command.env.TAP_TOKEN, '${{ steps.tap-token.outputs.token }}');
  assert.match(command.run, /python3 -B scripts\/homebrew\/update.py "\$TAG"/);
  assert.doesNotMatch(JSON.stringify(flow), /release\.published|RELEASE_APP_PRIVATE_KEY|publish\.mjs|package\.yml|secrets: inherit/);
});
