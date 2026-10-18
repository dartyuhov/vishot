'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
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
      return new Response(typeof value === 'string' ? value : JSON.stringify(value ?? {}), { status: value === undefined ? 404 : 200 });
    },
    now: () => now,
  });
  const server = http.createServer(async (req, res) => {
    if (req.url === '/') return res.end(await metadata.page(options.html ?? fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8')));
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
const assets = version => ['arm64', 'x86_64'].flatMap(arch => ['', '.sha256', '.json'].map(suffix => {
  const dmg = asset(version, arch);
  const body = sidecar(version, arch, suffix);
  return { ...dmg, name: dmg.name + suffix, browser_download_url: dmg.browser_download_url + suffix,
    size: suffix ? Buffer.byteLength(body) : 1234,
    digest: `sha256:${suffix ? hash(body) : digests[arch]}` };
}));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const digests = { arm64: 'a'.repeat(64), x86_64: 'b'.repeat(64) };
const source = 'c'.repeat(40);
const lock = 'controlled lockfile\n';
function sidecar(version, arch, suffix) {
  const name = asset(version, arch).name;
  return suffix === '.sha256' ? `${digests[arch]}  ${name}\n` : JSON.stringify({
    asset: name, sha256: digests[arch], architecture: arch, version, build: version,
    source_commit: source, package_resolved_sha256: hash(lock), xcode: 'Xcode 16.4', swift: 'Swift 6.1.2',
  });
}
const release = (version, extra = {}) => ({ tag_name: `v${version}`, draft: false, prerelease: false,
  published_at: '2026-10-18T12:00:00Z', html_url: `https://github.com/dartyuhov/vishot/releases/tag/v${version}`,
  assets: assets(version), ...extra });
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
    ...Object.fromEntries(releases.flatMap(r => {
      const version = r.tag_name.slice(1);
      return [
        [`/repos/dartyuhov/vishot/commits/${r.tag_name}`, { sha: source }],
        ...['arm64', 'x86_64'].flatMap(arch => ['.sha256', '.json'].map(suffix => [
          `/dartyuhov/vishot/releases/download/${r.tag_name}/${asset(version, arch).name}${suffix}`,
          sidecar(version, arch, suffix),
        ])),
      ];
    })),
    [`/repos/dartyuhov/vishot/contents/Package.resolved?ref=${source}`]: { encoding: 'base64', content: Buffer.from(lock).toString('base64') },
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
  assert.ok(site.calls.every(call => !Object.keys(call.init.headers || {}).some(key => key.toLowerCase() === 'authorization')));
  assert.ok(site.calls.every(call => !call.url.endsWith('.dmg')), 'never download installers for metadata');
});

test('skips a newer malformed release and selects the older complete release matching the cask', async t => {
  for (const defect of ['provenance', 'checksum', 'json', 'digest']) {
    const newer = release('0.3.0');
    const responses = publicResponses([newer, release('0.2.0')]);
    const suffix = defect === 'checksum' ? '.sha256' : '.json';
    const name = `Vishot-0.3.0-arm64.dmg${suffix}`;
    const route = `/dartyuhov/vishot/releases/download/v0.3.0/${name}`;
    responses[route] = defect === 'provenance'
      ? responses[route].replace(source, 'd'.repeat(40))
      : defect === 'checksum' ? `${'f'.repeat(64)}  Vishot-0.3.0-arm64.dmg\n` : '{';
    const metadata = newer.assets.find(a => a.name === name);
    metadata.size = Buffer.byteLength(responses[route]);
    if (defect !== 'digest') metadata.digest = `sha256:${hash(responses[route])}`;
    const site = await served(t, { enabled: true, responses });
    const value = await site.get('/api/install');
    assert.equal(value.ready, true, defect);
    assert.equal(value.version, '0.2.0', defect);
    assert.equal(value.arm64, 'https://github.com/dartyuhov/vishot/releases/download/v0.2.0/Vishot-0.2.0-arm64.dmg');
    assert.equal((await site.response('/download')).headers.get('location'), value.release);
  }
});

test('candidate request failures fail closed and expire cached readiness even alongside malformed content', async t => {
  for (const missing of ['commit', 'lockfile', 'sidecar']) {
    const site = await served(t, { enabled: true, responses: publicResponses() });
    assert.equal((await site.get('/api/install')).ready, true);
    const newer = release('0.3.0');
    const responses = publicResponses([newer, release('0.2.0')]);
    // One concurrent branch has invalid bytes; the other request failure must
    // still abort the scan rather than advertise the older cached release.
    responses['/dartyuhov/vishot/releases/download/v0.3.0/Vishot-0.3.0-arm64.dmg.json'] = '{';
    const route = missing === 'commit' ? '/repos/dartyuhov/vishot/commits/v0.3.0'
      : missing === 'lockfile' ? `/repos/dartyuhov/vishot/contents/Package.resolved?ref=${source}`
        : '/dartyuhov/vishot/releases/download/v0.3.0/Vishot-0.3.0-x86_64.dmg.json';
    delete responses[route];
    site.respond(responses);
    site.advance(900001);
    assert.deepEqual(await site.get('/api/install'), { ready: false }, missing);
    assert.equal((await site.response('/download')).headers.get('location'), '/#install');
    const count = site.calls.length;
    site.respond(publicResponses());
    assert.deepEqual(await site.get('/api/install'), { ready: false });
    assert.equal(site.calls.length, count, 'request failures retain the retry backoff');
    site.advance(60001);
    assert.equal((await site.get('/api/install')).ready, true);
  }
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

test('two DMGs without the four checksum/provenance sidecars cannot enable installation', async t => {
  const site = await served(t, { enabled: true, responses: publicResponses([
    release('0.2.0', { assets: [asset('0.2.0', 'arm64'), asset('0.2.0', 'x86_64')] }),
  ]) });
  assert.deepEqual(await site.get('/api/install'), { ready: false });
});

test('a cask with well-formed but wrong architecture checksums cannot enable installation', async t => {
  for (const architecture of ['arm64', 'x86_64']) {
    const responses = publicResponses();
    responses['/repos/dartyuhov/homebrew-tap/contents/Casks/vishot.rb'].content =
      Buffer.from(cask.replace(digests[architecture], 'f'.repeat(64))).toString('base64');
    const site = await served(t, { enabled: true, responses });
    assert.deepEqual(await site.get('/api/install'), { ready: false });
  }
});

test('every asset and downloaded sidecar must have matching size, digest and release identity', async t => {
  for (let index = 0; index < 6; index++) {
    for (const change of [a => { delete a.digest; }, a => { a.digest = 'sha256:' + '0'.repeat(64); },
      a => { a.state = 'new'; }, a => { a.size = 0; },
      a => { a.browser_download_url = 'https://example.org/untrusted'; }]) {
      const responses = publicResponses();
      change(responses['/repos/dartyuhov/vishot/releases?per_page=100&page=1'][0].assets[index]);
      const site = await served(t, { enabled: true, responses });
      assert.deepEqual(await site.get('/api/install'), { ready: false }, `asset ${index}`);
    }
  }
  for (const suffix of ['.sha256', '.json']) {
    const responses = publicResponses();
    const route = `/dartyuhov/vishot/releases/download/v0.2.0/Vishot-0.2.0-arm64.dmg${suffix}`;
    responses[route] = 'corrupted sidecar';
    const site = await served(t, { enabled: true, responses });
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
  assert.equal(site.calls.length, 10);
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

test('a damaged installation template fails safely instead of publishing partially substituted controls', async t => {
  const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
  for (const damaged of [html.replace('{{ARM64_URL}}', '/download'), html + html, html + '{{UNKNOWN}}']) {
    const site = await served(t, { enabled: true, responses: publicResponses(), html: damaged });
    const body = await (await site.response('/')).text();
    assert.doesNotMatch(body, /brew install --cask|releases\/download\//);
    assert.match(body, /Installation temporarily unavailable/);
  }
});

test('looks past a full page of incomplete releases instead of guessing a latest asset URL', async t => {
  const responses = publicResponses();
  responses['/repos/dartyuhov/vishot/releases?per_page=100&page=1'] = Array.from({ length: 100 }, () => release('0.3.0', { assets: [] }));
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
    const value = responses[parsed.pathname + parsed.search];
    return new Response(typeof value === 'string' ? value : JSON.stringify(value));
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
