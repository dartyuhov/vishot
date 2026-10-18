'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

test('production server defaults to gated installation and serves only the installer client', async t => {
  const volume = fs.mkdtempSync(path.join(os.tmpdir(), 'vishot-install-'));
  const child = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    env: { ...process.env, PORT: '0', RAILWAY_VOLUME_MOUNT_PATH: volume, VISHOT_INSTALL_READY: '' },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  t.after(async () => {
    if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); child.kill('SIGTERM'); });
    fs.rmSync(volume, { recursive: true, force: true });
  });
  const base = await new Promise((resolve, reject) => {
    child.stdout.on('data', data => {
      const port = /listening on (\d+)/.exec(data)?.[1];
      if (port) resolve(`http://127.0.0.1:${port}`);
    });
    child.once('exit', code => reject(new Error(`server exited: ${code}`)));
  });
  const html = await (await fetch(base)).text();
  assert.match(html, /data-install-controls hidden/);
  assert.doesNotMatch(html, /brew install --cask|releases\/download\//);
  assert.match(html, /href="https:\/\/github.com\/dartyuhov\/vishot"/);
  assert.match(html, /data-stars hidden/);
  const client = await fetch(base + '/install.js');
  assert.equal(client.status, 200);
  assert.match(client.headers.get('content-type'), /^text\/javascript/);
  assert.deepEqual(await (await fetch(base + '/api/install')).json(), { ready: false });
  assert.equal((await fetch(base + '/api/install', { method: 'POST' })).status, 405);
  const redirect = await fetch(base + '/download', { redirect: 'manual' });
  assert.equal(redirect.headers.get('location'), '/#install');
  for (const route of ['/metadata.js', '/metadata.test.js', '/install.test.js', '/fixtures/install-preview.cjs', '/waitlist.db']) {
    assert.equal((await fetch(base + route)).status, 404, route);
  }
});
