import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { parse } from 'yaml';

async function workflow(name) {
  return parse(await readFile(new URL(`../../../.github/workflows/${name}.yml`, import.meta.url), 'utf8'));
}

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
