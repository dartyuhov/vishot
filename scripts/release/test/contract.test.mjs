import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { validatePackages } from '../publication.mjs';

const require = createRequire(import.meta.url);
const { createMetadata } = require('../../../site/metadata.js');
const { hash } = require('../../../site/release-contract.js');
const root = new URL('../../../', import.meta.url);

// One concrete package crosses the actual Python cask CLI, JS publication, and
// public-site boundaries. Independent Python validation deliberately remains;
// this check prevents its manifest contract drifting from the JS consumer.
test('publication, Homebrew, and site agree on package provenance and checksums', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'vishot-contract-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const version = '1.2.3', sha = 'c'.repeat(40), lock = Buffer.from('controlled dependencies\n');
  const approval = { version, sha, lockHash: hash(lock) };
  const repo = 'https://github.com/dartyuhov/vishot';
  const release = { tag_name: 'v1.2.3', draft: false, prerelease: false,
    published_at: '2026-10-18T12:00:00Z', html_url: `${repo}/releases/tag/v1.2.3`, assets: [] };
  const files = new Map();
  for (const architecture of ['arm64', 'x86_64']) {
    const asset = `Vishot-${version}-${architecture}.dmg`;
    const bytes = Buffer.from(`controlled ${architecture} bytes, not an installer\n`);
    files.set(asset, bytes);
    files.set(`${asset}.sha256`, Buffer.from(`${hash(bytes)}  ${asset}\n`));
    files.set(`${asset}.json`, Buffer.from(JSON.stringify({ asset, architecture, version,
      build: version, sha256: hash(bytes), source_commit: sha,
      package_resolved_sha256: hash(lock), xcode: 'Xcode 16.4', swift: 'Swift 6.1.2' })));
  }
  await writeFile(join(directory, 'Package.resolved'), lock);
  await writeFile(join(directory, 'repository.json'), JSON.stringify({ full_name: 'dartyuhov/vishot', private: false, visibility: 'public' }));
  const generate = () => spawnSync('python3', ['-B', new URL('scripts/homebrew/cask.py', root).pathname,
    'generate', '--packages', directory, '--release', join(directory, 'release.json'),
    '--repository', join(directory, 'repository.json'), '--source-commit', sha,
    '--lockfile', join(directory, 'Package.resolved')], { encoding: 'utf8' });
  async function sync() {
    release.assets = [];
    for (const [name, bytes] of files) {
      await writeFile(join(directory, name), bytes);
      release.assets.push({ name, state: 'uploaded', size: bytes.length,
        digest: `sha256:${hash(bytes)}`, browser_download_url: `${repo}/releases/download/v${version}/${name}` });
    }
    await writeFile(join(directory, 'release.json'), JSON.stringify(release));
  }
  await sync();
  const cask = generate();
  assert.equal(cask.status, 0, cask.stderr);
  const fetch = async (url, init) => {
    assert.equal(new Headers(init?.headers).has('authorization'), false);
    const route = new URL(url).pathname;
    let value;
    if (route.endsWith('/releases')) value = [release];
    else if (route.endsWith('/commits/v1.2.3')) value = { sha };
    else if (route.endsWith('/contents/Package.resolved')) value = { encoding: 'base64', content: lock.toString('base64') };
    else if (route.endsWith('/Casks/vishot.rb')) value = { type: 'file', encoding: 'base64', content: Buffer.from(cask.stdout).toString('base64') };
    else if (url.startsWith(`${repo}/releases/download/`)) {
      assert.ok(!url.endsWith('.dmg'), 'metadata must not download installers');
      return new Response(files.get(route.split('/').at(-1)));
    } else value = { private: false, visibility: 'public', owner: { login: 'dartyuhov' } };
    return new Response(JSON.stringify(value));
  };
  validatePackages(files, approval);
  assert.equal((await createMetadata({ enabled: true, fetch }).install()).ready, true);
  const manifestName = 'Vishot-1.2.3-arm64.dmg.json';
  const original = files.get(manifestName);
  const manifest = JSON.parse(original);
  for (const [key, value] of [
    ['asset', 'wrong.dmg'], ['architecture', 'x86_64'], ['version', '1.2.4'],
    ['build', '2'], ['sha256', 'f'.repeat(64)], ['source_commit', 'd'.repeat(40)],
    ['package_resolved_sha256', 'e'.repeat(64)], ['xcode', ''], ['swift', null],
  ]) {
    files.set(manifestName, Buffer.from(JSON.stringify({ ...manifest, [key]: value })));
    await sync();
    assert.throws(() => validatePackages(files, approval), undefined, key);
    assert.notEqual(generate().status, 0, key);
    assert.equal((await createMetadata({ enabled: true, fetch }).install()).ready, false, key);
  }
  files.set(manifestName, original);
  for (const name of [...files.keys()]) {
    const bytes = files.get(name);
    files.delete(name);
    await sync();
    assert.throws(() => validatePackages(files, approval), undefined, name);
    assert.notEqual(generate().status, 0, name);
    assert.equal((await createMetadata({ enabled: true, fetch }).install()).ready, false, name);
    files.set(name, bytes);
  }
  files.set('unexpected.txt', Buffer.from('unexpected release asset'));
  await sync();
  assert.throws(() => validatePackages(files, approval));
  assert.notEqual(generate().status, 0, 'exact six-asset release contract');
  assert.equal((await createMetadata({ enabled: true, fetch }).install()).ready, false);
});
