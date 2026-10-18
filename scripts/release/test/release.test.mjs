import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { Manifest } from 'release-please';

const root = new URL('../../../', import.meta.url);
const quiet = { info() {}, warn() {}, error() {}, debug() {}, trace() {} };

// Only the external SCM boundary is substituted. Release Please itself loads the
// real config and owns commit parsing, path filtering, bumps, notes, and updates.
async function releaseRepository(messages, { version, files = ['Sources/Vishot/Capturer.swift'], scmOverrides = {} } = {}) {
  const published = version && version !== '0.0.0';
  const scm = {
    repository: { owner: 'dartyuhov', repo: 'vishot' },
    async getFileJson(path) {
      // Repository history/version are scenario data, so these tests also pass
      // on the bot's version-changing PRs. The release config is never replaced.
      const content = path === '.release-please-manifest.json'
        ? JSON.stringify({ '.': version ?? '0.0.0' }) : await readFile(new URL(path, root), 'utf8');
      return JSON.parse(content);
    },
    async *releaseIterator() {
      if (published) yield { tagName: `v${version}`, sha: 'released', notes: '' };
    },
    async *tagIterator() {},
    async *mergeCommitIterator() {
      for (const [index, message] of messages.entries()) {
        yield { sha: `${index}`.padStart(40, 'a'), message, files };
      }
      if (published) yield { sha: 'released', message: `chore: release ${version}`, files: [] };
    },
    ...scmOverrides,
  };
  return Manifest.fromManifest(scm, 'main', undefined, undefined, { logger: quiet });
}

async function candidate(messages, options) {
  return (await releaseRepository(messages, options)).buildPullRequests();
}

test('checked-in app version and managed manifest agree', async () => {
  const version = (await readFile(new URL('version.txt', root), 'utf8')).trim();
  const manifest = JSON.parse(await readFile(new URL('.release-please-manifest.json', root), 'utf8'));
  assert.equal(manifest['.'], version);
  assert.match(version, /^\d+\.\d+\.\d+$/);
});

test('first app release is regular 0.1.0 regardless of prelaunch features or breaking changes', async () => {
  const prs = await candidate(['feat!: replace capture API', 'feat: add editor', 'fix: repair capture']);
  assert.equal(prs.length, 1);
  const [pr] = prs;
  assert.equal(pr.version.toString(), '0.1.0');
  assert.equal(pr.draft, false);
  assert.match(pr.title.toString(), /^chore.*: release.*0\.1\.0$/);
  const updates = Object.fromEntries(pr.updates.map(update => [update.path, update.updater]));
  assert.equal(updates['version.txt'].updateContent('0.0.0\n'), '0.1.0\n');
  assert.equal(JSON.parse(updates['.release-please-manifest.json'].updateContent('{}'))['.'], '0.1.0');
  assert.match(updates['CHANGELOG.md'].updateContent(''), /0\.1\.0[\s\S]*add editor/);
});

test('published versions follow patch/minor/major semantics, including before 1.0', async () => {
  for (const [version, message, expected] of [
    ['0.1.0', 'fix: repair copy', '0.1.1'],
    ['0.1.7', 'feat: add region capture', '0.2.0'],
    ['0.1.7', 'feat(capture)!: replace selection behavior', '1.0.0'],
    ['0.1.7', 'fix!: require a new settings format', '1.0.0'],
    ['0.1.7', 'refactor: replace settings\n\nBREAKING CHANGE: old files are unsupported', '1.0.0'],
    ['1.2.3', 'fix: repair copy', '1.2.4'],
    ['1.2.3', 'feat: add region capture', '1.3.0'],
    ['1.2.3', 'feat!: replace selection behavior', '2.0.0'],
  ]) {
    const [pr] = await candidate([message], { version });
    assert.equal(pr?.version.toString(), expected, message);
  }
});

test('accumulated changes select the highest bump on the same managed release branch', async () => {
  const options = { version: '0.1.2' };
  const [patch] = await candidate(['fix: repair copy'], options);
  const [minor] = await candidate(['feat: add region', 'fix: repair copy'], options);
  const [major] = await candidate(['fix: repair copy', 'feat!: replace shortcuts', 'feat: add region'], options);
  assert.equal(minor.version.toString(), '0.2.0');
  assert.equal(major.version.toString(), '1.0.0');
  assert.equal(patch.headRefName, minor.headRefName);
  assert.equal(minor.headRefName, major.headRefName);
  assert.match(minor.body.toString(), /add region[\s\S]*repair copy/);
});

test('docs and site changes cannot independently release the app, even with feature titles', async () => {
  for (const version of [undefined, '0.1.2']) {
    for (const [message, files] of [
      ['docs: explain installation', ['README.md']],
      ['chore: update contributors', ['CONTRIBUTING.md']],
      ['feat: add release guide', ['docs/releases/guide.md']],
      ['feat(site): add download chooser', ['site/index.html', 'site/main.js']],
      ['fix(site)!: change signup API', ['site/server.js']],
    ]) {
      assert.deepEqual(await candidate([message], { version, files }), [], message);
    }
  }
});

test('app dependency, packaging, and workflow fixes can explicitly request an app patch', async () => {
  for (const [message, files] of [
    ['fix(deps): update app dependency', ['Package.resolved']],
    ['fix(packaging): include missing fonts', ['scripts/build.sh']],
    ['fix(release): repair publication', ['.github/workflows/release.yml']],
  ]) {
    const [pr] = await candidate([message], { version: '0.1.2', files });
    assert.equal(pr?.version.toString(), '0.1.3', message);
  }
});

test('Release Please creates one PR, updates that PR, and leaves it alone when unchanged', async () => {
  const messages = ['fix: repair copy'];
  let stored;
  let creates = 0;
  let updates = 0;
  const manifest = await releaseRepository(messages, {
    version: '0.1.2',
    scmOverrides: {
      async *pullRequestIterator(branch, state) {
        assert.equal(branch, 'main');
        if (state === 'OPEN' && stored) yield stored;
      },
      async createPullRequest(pr, branch, message, fileUpdates) {
        creates++;
        assert.equal(branch, 'main');
        assert.equal(message, pr.title);
        assert.ok(fileUpdates.some(update => update.path === '.release-please-manifest.json'));
        stored = { ...pr, number: 42 };
        return stored;
      },
      async updatePullRequest(number, pr, branch) {
        updates++;
        assert.equal(number, 42);
        assert.equal(branch, 'main');
        stored = { ...stored, title: pr.title.toString(), body: pr.body.toString() };
        return stored;
      },
    },
  });
  assert.equal((await manifest.createPullRequests())[0].number, 42);
  assert.match(stored.title, /0\.1\.3/);
  messages.unshift('feat: add region capture');
  assert.equal((await manifest.createPullRequests())[0].number, 42);
  assert.match(stored.title, /0\.2\.0/);
  assert.equal(creates, 1);
  assert.equal(updates, 1);
  assert.deepEqual(await manifest.createPullRequests(), []);
  assert.equal(updates, 1);
});

test('excluded site features cannot increase an accumulated app patch', async () => {
  const [pr] = await candidate([], {
    version: '0.1.2',
    scmOverrides: {
      async *mergeCommitIterator() {
        yield { sha: 'site', message: 'feat(site)!: replace signup', files: ['site/server.js'] };
        yield { sha: 'app', message: 'fix: repair copy', files: ['Sources/Vishot/Capturer.swift'] };
        yield { sha: 'released', message: 'chore: release 0.1.2', files: [] };
      },
    },
  });
  assert.equal(pr.version.toString(), '0.1.3');
  assert.doesNotMatch(pr.body.toString(), /replace signup/);
});

test('bootstrap SHA excludes historical commits while first launch stays 0.1.0', async () => {
  const config = JSON.parse(await readFile(new URL('release-please-config.json', root), 'utf8'));
  assert.match(config['bootstrap-sha'], /^[0-9a-f]{40}$/);
  const [pr] = await candidate([], {
    scmOverrides: {
      async *mergeCommitIterator() {
        yield { sha: 'new', message: 'feat: introduce downloads', files: ['scripts/build.sh'] };
        yield { sha: config['bootstrap-sha'], message: 'feat!: historical change', files: ['Package.swift'] };
        yield { sha: 'old', message: 'feat: obsolete behavior', files: ['Package.swift'] };
      },
    },
  });
  assert.equal(pr.version.toString(), '0.1.0');
  assert.match(pr.body.toString(), /introduce downloads/);
  assert.doesNotMatch(pr.body.toString(), /historical change|obsolete behavior/);
});

test('a merged release PR blocks new release PRs until publication clears its pending label', async () => {
  const [pending] = await candidate(['fix: repair copy'], { version: '0.1.2' });
  const manifest = await releaseRepository(['feat: add another tool'], {
    version: '0.1.2',
    scmOverrides: {
      async *pullRequestIterator(branch, state) {
        if (state === 'MERGED') yield {
          number: 42,
          title: pending.title.toString(),
          body: pending.body.toString(),
          headBranchName: pending.headRefName,
          labels: ['autorelease: pending'],
        };
      },
      async createPullRequest() { assert.fail('must finish the pending release first'); },
    },
  });
  assert.deepEqual(await manifest.createPullRequests(), []);
});
