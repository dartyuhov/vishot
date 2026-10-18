'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { createMetadata } = require('./metadata');

// Exercise the HTTP contract with controlled public GitHub responses, never live credentials.
async function served(t, options = {}) {
  const calls = [];
  let now = 0;
  let responses = options.responses || {};
  const metadata = createMetadata({
    enabled: options.enabled ?? false,
    fetch: async (url, init) => {
      calls.push({ url, init });
      const value = responses[new URL(url).pathname + new URL(url).search];
      return new Response(JSON.stringify(value ?? {}), { status: value === undefined ? 404 : 200 });
    },
    now: () => now,
  });
  const server = http.createServer(async (req, res) => {
    if (req.url === '/') return res.end(await metadata.page(fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8')));
    if (!await metadata.handle(req, res)) { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  return { calls, response: route => fetch(base + route, { redirect: 'manual' }), get: async route => (await fetch(base + route)).json(),
    advance: ms => { now += ms; }, respond: value => { responses = value; } };
}

test('installation is explicitly disabled by default, even with public release metadata', async t => {
  const site = await served(t);
  assert.deepEqual(await site.get('/api/install'), { ready: false });
  assert.equal(site.calls.length, 0);
});

const asset = (version, arch) => ({ name: `Vishot-${version}-${arch}.dmg`, state: 'uploaded', size: 1234,
  browser_download_url: `https://github.com/dartyuhov/vishot/releases/download/v${version}/Vishot-${version}-${arch}.dmg` });
const release = (version, extra = {}) => ({ tag_name: `v${version}`, draft: false, prerelease: false,
  published_at: '2026-10-18T12:00:00Z', html_url: `https://github.com/dartyuhov/vishot/releases/tag/v${version}`,
  assets: [asset(version, 'arm64'), asset(version, 'x86_64')], ...extra });
const cask = `cask "vishot" do
  arch arm: "arm64", intel: "x86_64"
  version "0.2.0"
  sha256 arm: "${'a'.repeat(64)}", intel: "${'b'.repeat(64)}"
  url "https://github.com/dartyuhov/vishot/releases/download/v#{version}/Vishot-#{version}-#{arch}.dmg"
  depends_on macos: ">= :sonoma"
  app "Vishot.app"
end`;
function publicResponses(releases = [release('0.2.0')]) {
  return {
    '/repos/dartyuhov/vishot': { private: false, visibility: 'public', stargazers_count: 42 },
    '/repos/dartyuhov/vishot/releases?per_page=100&page=1': releases,
    '/repos/dartyuhov/homebrew-tap': { private: false, visibility: 'public', owner: { login: 'dartyuhov' } },
    '/repos/dartyuhov/homebrew-tap/contents/Casks/vishot.rb': { type: 'file', encoding: 'base64', content: Buffer.from(cask).toString('base64') },
  };
}

test('serves the latest complete regular release and chip assets, skipping incomplete, prerelease and draft entries', async t => {
  const site = await served(t, { enabled: true, responses: publicResponses([
    release('0.5.0', { draft: true }), release('0.4.0', { prerelease: true }),
    release('0.3.0', { assets: [asset('0.3.0', 'arm64')] }), release('0.2.0'), release('0.1.0'),
  ]) });
  assert.deepEqual(await site.get('/api/install'), {
    ready: true, version: '0.2.0', command: 'brew install --cask dartyuhov/tap/vishot',
    release: 'https://github.com/dartyuhov/vishot/releases/tag/v0.2.0',
    arm64: 'https://github.com/dartyuhov/vishot/releases/download/v0.2.0/Vishot-0.2.0-arm64.dmg',
    x86_64: 'https://github.com/dartyuhov/vishot/releases/download/v0.2.0/Vishot-0.2.0-x86_64.dmg',
  });
  assert.ok(site.calls.every(call => !call.init.headers.Authorization));
});

test('fails closed for missing public repositories, incomplete releases, or an absent/mismatched cask', async t => {
  for (const change of [
    { '/repos/dartyuhov/vishot': { private: true, visibility: 'private' } },
    { '/repos/dartyuhov/homebrew-tap': { private: true } },
    { '/repos/dartyuhov/homebrew-tap/contents/Casks/vishot.rb': undefined },
    { '/repos/dartyuhov/homebrew-tap/contents/Casks/vishot.rb': { type: 'file', encoding: 'base64', content: Buffer.from(cask.replace('0.2.0', '0.1.0')).toString('base64') } },
    { '/repos/dartyuhov/vishot/releases?per_page=100&page=1': [release('0.2.0', { assets: [asset('0.2.0', 'arm64')] })] },
    { '/repos/dartyuhov/vishot/releases?per_page=100&page=1': [release('0.2.0', { assets: [asset('0.2.0', 'arm64'), { ...asset('0.2.0', 'x86_64'), browser_download_url: 'https://example.org/wrong.dmg' }] })] },
  ]) {
    const site = await served(t, { enabled: true, responses: { ...publicResponses(), ...change } });
    assert.deepEqual(await site.get('/api/install'), { ready: false });
  }
});

test('stars are real, cached and retained on failure; unavailable stars are null, never an invented zero', async t => {
  const site = await served(t, { responses: publicResponses() });
  assert.deepEqual(await site.get('/api/github'), { stars: 42 });
  site.respond({});
  assert.deepEqual(await site.get('/api/github'), { stars: 42 });
  assert.equal(site.calls.length, 1);
  site.advance(900001);
  assert.deepEqual(await site.get('/api/github'), { stars: 42 });
  assert.equal(site.calls.length, 2);
  await site.get('/api/github');
  assert.equal(site.calls.length, 2, 'back off after API failure');
  const unavailable = await served(t);
  assert.deepEqual(await unavailable.get('/api/github'), { stars: null });
});

test('installation caching coalesces requests and expires safely on API failure', async t => {
  const site = await served(t, { enabled: true, responses: publicResponses() });
  const values = await Promise.all(Array.from({ length: 8 }, () => site.get('/api/install')));
  assert.ok(values.every(value => value.ready));
  assert.equal(site.calls.length, 4);
  site.respond({});
  site.advance(900001);
  assert.deepEqual(await site.get('/api/install'), { ready: false });
});

test('no-JavaScript download route redirects to the exact verified release, or honest status', async t => {
  const ready = await served(t, { enabled: true, responses: publicResponses() });
  const res = await ready.response('/download');
  assert.equal(res.status, 302);
  assert.equal(res.headers.get('location'), 'https://github.com/dartyuhov/vishot/releases/tag/v0.2.0');
  const disabled = await served(t);
  assert.equal((await disabled.response('/download')).headers.get('location'), '/#install');
});

test('renders usable installation links without JavaScript only when release and tap are verified', async t => {
  const ready = await served(t, { enabled: true, responses: publicResponses() });
  const html = await (await ready.response('/')).text();
  assert.match(html, /data-install-controls>/);
  assert.match(html, /data-brew-command>brew install --cask dartyuhov\/tap\/vishot<\/code>/);
  assert.match(html, /data-download href="\/download"/);
  assert.match(html, /data-arm64 href="https:\/\/github.com\/dartyuhov\/vishot\/releases\/download\/v0.2.0\/Vishot-0.2.0-arm64.dmg"/);
  const disabled = await served(t);
  const unavailable = await (await disabled.response('/')).text();
  assert.match(unavailable, /data-install-controls hidden/);
  assert.doesNotMatch(unavailable, /brew install --cask|releases\/download\//);
});

test('looks past a full page of incomplete releases instead of guessing a latest asset URL', async t => {
  const responses = publicResponses(Array.from({ length: 100 }, () => release('0.3.0', { assets: [] })));
  responses['/repos/dartyuhov/vishot/releases?per_page=100&page=2'] = [release('0.2.0')];
  const site = await served(t, { enabled: true, responses });
  assert.equal((await site.get('/api/install')).version, '0.2.0');
});

test('an optional star request in flight does not block the installation path', async t => {
  let finish;
  let calls = 0;
  const responses = publicResponses();
  const metadata = createMetadata({ enabled: true, fetch: async url => {
    if (++calls === 1) return new Promise(resolve => { finish = () => resolve(new Response('{}', { status: 403 })); });
    const parsed = new URL(url);
    return new Response(JSON.stringify(responses[parsed.pathname + parsed.search]));
  } });
  const server = http.createServer((req, res) => metadata.handle(req, res));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const stars = fetch(base + '/api/github');
  while (!finish) await new Promise(resolve => setImmediate(resolve));
  try {
    const install = await fetch(base + '/api/install', { signal: AbortSignal.timeout(1000) });
    assert.equal((await install.json()).ready, true);
  } finally { finish(); await stars; }
});
