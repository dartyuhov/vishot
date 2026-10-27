import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { GitHub, approve, publish, recoverPublishedLabels } from '../publication.mjs';

const sha = 'a'.repeat(40);
const lock = Buffer.from('locked dependencies\n');
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const repo = 'owner/vishot';
const bot = 'release-app[bot]';

function packages(version = '0.1.0', commit = sha) {
  const files = new Map();
  for (const architecture of ['arm64', 'x86_64']) {
    const asset = `Vishot-${version}-${architecture}.dmg`;
    const bytes = Buffer.from(`native ${architecture} installer`);
    files.set(asset, bytes);
    files.set(`${asset}.sha256`, Buffer.from(`${digest(bytes)}  ${asset}\n`));
    files.set(`${asset}.json`, Buffer.from(JSON.stringify({
      asset, sha256: digest(bytes), architecture, version, build: version,
      source_commit: commit, package_resolved_sha256: digest(lock),
      xcode: 'Xcode 16.4', swift: 'Swift 6.1.2',
    })));
  }
  return files;
}

// The real HTTP adapter runs against a controlled transport. Match GitHub's
// wire responses (not a second, idealized release client).
function repository() {
  const state = {
    pr: { number: 42, merged: true, merged_at: '2026-10-18T10:00:00Z',
      merge_commit_sha: sha, user: { login: bot },
      title: 'chore(main): release 0.1.0',
      body: ':robot: I have created a release *beep* *boop*\n---\n\n## 0.1.0\n\n### Features\n\n* native installers\n\n---',
      labels: [{ name: 'autorelease: pending' }],
      base: { ref: 'main', repo: { full_name: repo } },
      head: { ref: 'release-please--branches--main', repo: { full_name: repo } } },
    releases: [], refs: new Map(), bytes: new Map(), calls: [], next: 1,
    failUpload: false, failPublish: false, compareStatus: 'ahead',
  };
  const contents = {
    'version.txt': '0.1.0\n', '.release-please-manifest.json': '{".":"0.1.0"}',
    'Resources/Info.plist': '<key>CFBundleShortVersionString</key>\n<string>0.1.0</string>\n<key>CFBundleVersion</key>\n<string>0.1.0</string>',
    'Package.resolved': lock,
  };
  const respond = (data, status = 200) => new Response(
    Buffer.isBuffer(data) ? data : JSON.stringify(data), { status });
  const fetch = async (url, init = {}) => {
    const u = new URL(url);
    const method = init.method ?? 'GET';
    const path = u.pathname.replace(`/repos/${repo}`, '');
    const body = init.body && !Buffer.isBuffer(init.body) ? JSON.parse(init.body) : init.body;
    state.calls.push({ method, path, body, host: u.host });
    state.intercept?.({ method, path, body });
    if (path === '/pulls') return respond([state.pr]);
    if (path === '/pulls/42') return respond(state.pr);
    if (path.startsWith('/releases/tags/')) {
      const release = state.releases.find(r => r.tag_name === path.slice(15));
      return release ? respond(release) : respond({}, 404);
    }
    if (path === `/commits/${sha}/pulls`) return respond([state.pr]);
    if (path.startsWith('/compare/')) return respond({ status: state.compareStatus });
    if (path.startsWith('/contents/')) {
      assert.equal(u.searchParams.get('ref'), sha);
      return respond({ encoding: 'base64', content: Buffer.from(contents[decodeURIComponent(path.slice(10))]).toString('base64') });
    }
    if (path.startsWith('/git/ref/tags/')) {
      const target = state.refs.get(path.slice(14));
      return target ? respond({ object: { type: 'commit', sha: target } }) : respond({}, 404);
    }
    if (path.startsWith('/git/tags/')) return respond({ object: { type: 'commit', sha } });
    if (path === '/git/refs' && method === 'POST') {
      const tag = body.ref.replace('refs/tags/', '');
      if (state.refs.has(tag)) return respond({}, 422);
      state.refs.set(tag, body.sha);
      return respond({ object: { type: 'commit', sha: body.sha } }, 201);
    }
    if (path === '/releases' && method === 'GET') {
      // Deliberately paginate drafts as the API does, rather than assume
      // /releases/tags/{tag} will locate every recoverable draft.
      const page = Number(u.searchParams.get('page') ?? 1);
      return respond(state.releases.slice((page - 1) * 100, page * 100));
    }
    if (path === '/releases' && method === 'POST') {
      assert.equal(body.draft, true);
      const release = { ...body, id: state.next++, assets: [],
        upload_url: `https://uploads.github.com/repos/${repo}/releases/1/assets{?name,label}` };
      state.releases.push(release);
      return respond(release, 201);
    }
    const releaseMatch = path.match(/^\/releases\/(\d+)$/);
    if (releaseMatch) {
      const release = state.releases.find(r => r.id === Number(releaseMatch[1]));
      if (method === 'PATCH') {
        if (state.failPublish) return respond({}, 503);
        Object.assign(release, body);
      }
      return respond(release);
    }
    const assetsMatch = path.match(/^\/releases\/(\d+)\/assets$/);
    if (assetsMatch) {
      const release = state.releases.find(r => r.id === Number(assetsMatch[1]));
      if (method === 'GET') return respond(release.assets);
      assert.equal(u.host, 'uploads.github.com');
      const name = u.searchParams.get('name');
      if (release.assets.some(a => a.name === name)) return respond({}, 422);
      const asset = { id: state.next++, name, state: 'uploaded', size: body.length };
      release.assets.push(asset);
      state.bytes.set(asset.id, body);
      if (state.failUpload) {
        state.failUpload = false;
        asset.state = 'starter';
        return respond({}, 502);
      }
      return respond(asset, 201);
    }
    const assetMatch = path.match(/^\/releases\/assets\/(\d+)$/);
    if (assetMatch) {
      const id = Number(assetMatch[1]);
      if (method === 'DELETE') {
        for (const release of state.releases) release.assets = release.assets.filter(a => a.id !== id);
        state.bytes.delete(id);
        return new Response(null, { status: 204 });
      }
      assert.equal(init.headers.Accept, 'application/octet-stream');
      return respond(state.bytes.get(id));
    }
    if (path === '/issues/42/labels' && method === 'POST') {
      for (const name of body.labels) if (!state.pr.labels.some(l => l.name === name)) state.pr.labels.push({ name });
      return respond(state.pr.labels);
    }
    if (path === '/issues/42/labels/autorelease%3A%20pending' && method === 'DELETE') {
      state.pr.labels = state.pr.labels.filter(l => l.name !== 'autorelease: pending');
      return respond(state.pr.labels);
    }
    throw new Error(`Unexpected API call: ${method} ${url}`);
  };
  return { state, contents, api: new GitHub({ repo, token: 'test', fetch }) };
}

test('a merged bot release PR authorizes its exact source, regular version, and native assets', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { sourceSha: sha, bot });
  assert.equal(approval.sha, sha);
  assert.equal(approval.version, '0.1.0');
  await publish(api, approval, packages());
  assert.equal(state.releases.length, 1);
  assert.equal(state.releases[0].draft, false);
  assert.equal(state.releases[0].prerelease, false);
  assert.equal(state.releases[0].make_latest, 'true');
  assert.equal(state.refs.get('v0.1.0'), sha);
  assert.equal(state.releases[0].assets.length, 6);
  assert.deepEqual(state.pr.labels, [{ name: 'autorelease: tagged' }]);
});

test('main push recovery verifies public bytes before repairing stale labels and is idempotent', async () => {
  const { api, state } = repository();
  await publish(api, await approve(api, { prNumber: 42, bot }), packages());
  state.pr.labels = [{ name: 'autorelease: pending' }];
  state.calls = [];
  assert.deepEqual(await recoverPublishedLabels(api, { bot, readOnly: true }), [42]);
  assert.ok(state.calls.every(call => call.method === 'GET'));
  assert.deepEqual(state.pr.labels, [{ name: 'autorelease: pending' }]);
  state.calls = [];
  assert.deepEqual(await recoverPublishedLabels(api, { bot }), [42]);
  assert.deepEqual(state.pr.labels, [{ name: 'autorelease: tagged' }]);
  assert.ok(state.calls.filter(call => call.method !== 'GET').every(call => call.path.startsWith('/issues/42/labels')));
  assert.deepEqual(await recoverPublishedLabels(api, { bot }), []);
});

test('recovery leaves missing and draft releases pending without publishing them', async () => {
  const { api, state } = repository();
  assert.deepEqual(await recoverPublishedLabels(api, { bot }), []);
  state.failPublish = true;
  await assert.rejects(publish(api, await approve(api, { prNumber: 42, bot }), packages()));
  state.calls = [];
  assert.deepEqual(await recoverPublishedLabels(api, { bot }), []);
  assert.ok(state.calls.every(call => call.method === 'GET'));
  assert.equal(state.releases[0].draft, true);
});

test('recovery refuses corrupt assets, wrong release identity, and mismatched tags before label writes', async () => {
  for (const change of [
    state => { state.bytes.set(state.releases[0].assets[0].id, Buffer.from('corrupt')); },
    state => { state.releases[0].body = 'foreign release'; },
    state => { state.refs.set('v0.1.0', 'b'.repeat(40)); },
  ]) {
    const { api, state } = repository();
    await publish(api, await approve(api, { prNumber: 42, bot }), packages());
    state.pr.labels = [{ name: 'autorelease: pending' }];
    change(state);
    state.calls = [];
    await assert.rejects(recoverPublishedLabels(api, { bot }));
    assert.ok(state.calls.every(call => call.method === 'GET'));
    assert.deepEqual(state.pr.labels, [{ name: 'autorelease: pending' }]);
  }
});

test('ordinary merges do not publish and reruns require the actual merged release PR', async () => {
  const { api, state } = repository();
  state.pr.head.ref = 'fix/copy';
  assert.equal(await approve(api, { sourceSha: sha, bot }), undefined);
  await assert.rejects(approve(api, { prNumber: 42, bot }), /trusted Release Please/);
  assert.equal(state.calls.filter(c => c.method !== 'GET').length, 0);
});

test('unmerged, fork, wrong bot, missing labels, off-main, and version mismatch approvals fail closed', async () => {
  for (const change of [
    s => { s.pr.merged = false; },
    s => { s.pr.head.repo.full_name = 'attacker/vishot'; },
    s => { s.pr.user.login = 'attacker[bot]'; },
    s => { s.pr.labels = []; },
    s => { s.pr.title = 'chore(main): release 0.2.0'; },
    s => { s.pr.body = 'ordinary PR'; },
  ]) {
    const { api, state } = repository();
    change(state);
    await assert.rejects(approve(api, { prNumber: 42, bot }));
    assert.equal(state.calls.filter(c => c.method !== 'GET').length, 0);
  }
  const { api, contents } = repository();
  contents['Resources/Info.plist'] = '<key>CFBundleVersion</key><string>1</string>';
  await assert.rejects(approve(api, { prNumber: 42, bot }), /Bundle/);
});

test('missing assets, bad checksums, wrong source, architecture, and lockfile fail before mutations', async () => {
  for (const change of [
    files => files.delete('Vishot-0.1.0-arm64.dmg'),
    files => files.set('Vishot-0.1.0-arm64.dmg.sha256', Buffer.from('wrong')),
    ...['source_commit', 'architecture', 'package_resolved_sha256', 'version', 'build'].map(key => files => {
      const name = 'Vishot-0.1.0-x86_64.dmg.json';
      const manifest = JSON.parse(files.get(name));
      manifest[key] = 'wrong';
      files.set(name, Buffer.from(JSON.stringify(manifest)));
    }),
  ]) {
    const { api, state } = repository();
    const approval = await approve(api, { prNumber: 42, bot });
    const files = packages();
    change(files);
    await assert.rejects(publish(api, approval, files));
    assert.equal(state.calls.filter(c => c.method !== 'GET').length, 0);
  }
});

test('502 starter uploads leave a draft and retry repairs it without a duplicate release', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  state.failUpload = true;
  await assert.rejects(publish(api, approval, packages()), /502/);
  assert.equal(state.releases[0].draft, true);
  assert.equal(state.pr.labels[0].name, 'autorelease: pending');
  await publish(api, approval, packages());
  assert.equal(state.releases.length, 1);
  assert.equal(state.releases[0].draft, false);
  assert.equal(state.releases[0].assets.length, 6);
  assert.ok(state.calls.some(c => c.method === 'DELETE' && c.path.startsWith('/releases/assets/')));
});

test('failed final publication resumes and completed reruns verify original public bytes without writes', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  state.failPublish = true;
  await assert.rejects(publish(api, approval, packages()), /503/);
  assert.equal(state.releases[0].draft, true);
  assert.equal(state.releases[0].assets.length, 6);
  state.failPublish = false;
  await publish(api, approval, packages());
  const uploads = state.calls.filter(c => c.host === 'uploads.github.com').length;
  assert.equal(uploads, 6);
  const before = state.calls.length;
  assert.equal((await publish(api, approval, packages())).status, 'already-published');
  assert.equal(state.calls.slice(before).filter(c => c.method !== 'GET' && !c.path.startsWith('/issues/')).length, 0);
  // A corrupt public asset is never repaired in place.
  state.bytes.set(state.releases[0].assets[0].id, Buffer.from('corrupt'));
  await assert.rejects(publish(api, approval, packages()), /mismatch/);
  assert.equal(state.calls.filter(c => c.host === 'uploads.github.com').length, uploads);
});

test('draft retries replace changed build bytes but public reruns accept validated original bytes', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  state.failPublish = true;
  await assert.rejects(publish(api, approval, packages()));
  const changed = packages();
  const name = 'Vishot-0.1.0-arm64.dmg';
  changed.set(name, Buffer.from('rebuilt disk image with new HFS timestamp'));
  changed.set(`${name}.sha256`, Buffer.from(`${digest(changed.get(name))}  ${name}\n`));
  const manifest = JSON.parse(changed.get(`${name}.json`));
  manifest.sha256 = digest(changed.get(name));
  changed.set(`${name}.json`, Buffer.from(JSON.stringify(manifest)));
  state.failPublish = false;
  await publish(api, approval, changed);
  assert.equal((await publish(api, approval, packages())).status, 'already-published');
});

test('a conflicting tag and a stale run behind a newer public release never mutate releases', async () => {
  for (const scenario of ['tag', 'stale']) {
    const { api, state } = repository();
    const approval = await approve(api, { prNumber: 42, bot });
    if (scenario === 'tag') state.refs.set('v0.1.0', 'b'.repeat(40));
    else {
      state.releases.push(...Array.from({ length: 100 }, (_, i) => ({ id: 1000 + i, draft: true, tag_name: `scratch-${i}` })));
      state.releases.push({ draft: false, prerelease: false, tag_name: 'v0.2.0' });
    }
    await assert.rejects(publish(api, approval, packages()), /tag\/source mismatch|Stale release/);
    assert.equal(state.calls.filter(c => c.method !== 'GET').length, 0);
  }
});

test('tagged PRs can only verify an existing public release, never create another draft', async () => {
  const { api, state } = repository();
  state.pr.labels = [{ name: 'autorelease: tagged' }];
  const approval = await approve(api, { prNumber: 42, bot });
  await assert.rejects(publish(api, approval, packages()), /pending/);
  assert.equal(state.calls.filter(c => c.method !== 'GET').length, 0);
});

test('approval is revalidated and off-main or diverged release history cannot publish', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  state.compareStatus = 'behind';
  await assert.rejects(publish(api, approval, packages()), /not on main/);
  assert.equal(state.calls.filter(c => c.method !== 'GET').length, 0);
});

test('remote corruption after upload is caught before publication', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  state.intercept = ({ method, path }) => {
    if (method === 'GET' && path === '/releases/1/assets' && state.releases[0]?.assets.length === 6) {
      const id = state.releases[0].assets[0].id;
      state.bytes.set(id, Buffer.from('corrupt remote bytes'));
    }
  };
  await assert.rejects(publish(api, approval, packages()), /mismatch/);
  assert.equal(state.releases[0].draft, true);
  assert.ok(!state.calls.some(c => c.method === 'PATCH'));
});

test('late stale-run guard refuses publication even after complete draft staging', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  let lists = 0;
  state.intercept = ({ method, path }) => {
    if (method === 'GET' && path === '/releases' && ++lists === 2) {
      state.releases.push({ tag_name: 'v0.2.0', draft: false, prerelease: false });
    }
  };
  await assert.rejects(publish(api, approval, packages()), /Stale release/);
  assert.equal(state.releases[0].draft, true);
  assert.ok(!state.calls.some(c => c.method === 'PATCH'));
});

test('a lost publish response resumes as a completed release and finishes lifecycle labels', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  state.intercept = ({ method }) => {
    if (method === 'PATCH') {
      state.releases[0].draft = false;
      throw new Error('Connection lost after server committed publication');
    }
  };
  await assert.rejects(publish(api, approval, packages()), /Connection lost/);
  assert.equal(state.pr.labels[0].name, 'autorelease: pending');
  state.intercept = undefined;
  assert.equal((await publish(api, approval, packages())).status, 'already-published');
  assert.deepEqual(state.pr.labels, [{ name: 'autorelease: tagged' }]);
});

test('a draft found beyond page one resumes and incomplete public assets remain untouched', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  state.failPublish = true;
  await assert.rejects(publish(api, approval, packages()));
  const draft = state.releases[0];
  state.releases.unshift(...Array.from({ length: 100 }, (_, i) => ({ id: 1000 + i, draft: true, tag_name: `scratch-${i}` })));
  state.failPublish = false;
  await publish(api, approval, packages());
  assert.equal(draft.draft, false);
  draft.assets.pop();
  const before = state.calls.length;
  await assert.rejects(publish(api, approval, packages()), /asset set/);
  assert.ok(state.calls.slice(before).every(c => c.method === 'GET'));
});

test('annotated tags resolve to the approved commit without being overwritten', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  const originalFetch = api.fetch;
  api.fetch = async (url, init) => {
    if (new URL(url).pathname.endsWith('/git/ref/tags/v0.1.0')) {
      return new Response(JSON.stringify({ object: { type: 'tag', sha: 'b'.repeat(40) } }));
    }
    return originalFetch(url, init);
  };
  await publish(api, approval, packages());
  assert.ok(!state.calls.some(c => c.method === 'POST' && c.path === '/git/refs'));
});

test('an interrupted release creation is found on retry instead of created twice', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  const originalFetch = api.fetch;
  let lost = false;
  api.fetch = async (url, init) => {
    const response = await originalFetch(url, init);
    if (!lost && init?.method === 'POST' && new URL(url).pathname.endsWith('/releases')) {
      lost = true;
      throw new Error('Lost create response');
    }
    return response;
  };
  await assert.rejects(publish(api, approval, packages()), /Lost create/);
  assert.equal(state.releases[0].draft, true);
  await publish(api, approval, packages());
  assert.equal(state.releases.length, 1);
  assert.equal(state.releases[0].draft, false);
});

test('foreign draft identity is rejected before any asset can be replaced', async () => {
  const { api, state } = repository();
  const approval = await approve(api, { prNumber: 42, bot });
  state.releases.push({ id: 1, tag_name: 'v0.1.0', target_commitish: sha,
    draft: true, prerelease: false, body: 'unrelated draft', assets: [] });
  await assert.rejects(publish(api, approval, packages()), /identity/);
  assert.ok(state.calls.every(c => c.method === 'GET'));
});
