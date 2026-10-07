// Runs server.js as Railway would, against a throwaway volume directory. `npm test`.

'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const TOKEN = 'test-export-token';
const volume = fs.mkdtempSync(path.join(os.tmpdir(), 'vishot-waitlist-'));
let server;
let base;

function start() {
  const child = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    env: { ...process.env, PORT: '0', RAILWAY_VOLUME_MOUNT_PATH: volume, EXPORT_TOKEN: TOKEN },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  return new Promise((resolve, reject) => {
    child.stdout.on('data', chunk => {
      const port = /listening on (\d+)/.exec(chunk)?.[1];
      if (port) resolve({ child, base: `http://127.0.0.1:${port}` });
    });
    child.on('exit', code => reject(new Error(`server exited with ${code}`)));
  });
}

function stop(child) {
  return new Promise(resolve => { child.on('exit', resolve); child.kill('SIGTERM'); });
}

// Each call comes from its own address so the rate limit only bites where a test wants it to.
let ip = 0;
function subscribe(fields, { json = true, from = `10.0.0.${++ip}` } = {}) {
  return fetch(`${base}/api/subscribe`, {
    method: 'POST',
    headers: { 'X-Forwarded-For': from, ...(json && { Accept: 'application/json' }) },
    body: new URLSearchParams(fields),
  });
}

async function exported() {
  const res = await fetch(`${base}/api/export.csv`, { headers: { Authorization: `Bearer ${TOKEN}` } });
  return (await res.text()).trim().split('\n').slice(1).map(row => row.split(',')[0]);
}

before(async () => ({ child: server, base } = await start()));
after(async () => {
  if (server) await stop(server);
  fs.rmSync(volume, { recursive: true, force: true });
});

test('serves the landing page and its assets', async () => {
  for (const [url, type] of [['/', 'text/html'], ['/main.js', 'text/javascript'], ['/style.css', 'text/css'],
    ['/favicon.svg', 'image/svg+xml'], ['/fonts/silkscreen-latin-400-normal.woff2', 'font/woff2']]) {
    const res = await fetch(base + url);
    assert.equal(res.status, 200, url);
    assert.ok(res.headers.get('content-type').startsWith(type), url);
  }
});

test('keeps server files and the database private', async () => {
  for (const url of ['/server.js', '/server.test.js', '/package.json', '/waitlist.db', '/../server.js', '/node_modules/']) {
    assert.equal((await fetch(base + url)).status, 404, url);
  }
});

test('subscribes a new address, normalized', async () => {
  const res = await subscribe({ email: '  New.Person@Example.com ' });
  assert.equal(res.status, 201);
  assert.deepEqual(await res.json(), { status: 'subscribed' });
  assert.ok((await exported()).includes('"new.person@example.com"'));
});

test('reports an address that is already on the list', async () => {
  await subscribe({ email: 'twice@example.com' });
  const res = await subscribe({ email: 'TWICE@example.com' });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { status: 'already' });
});

test('rejects something that is not an email address', async () => {
  for (const email of ['', 'nope', 'a@b', 'a b@example.com', `${'x'.repeat(250)}@example.com`]) {
    const res = await subscribe({ email });
    assert.equal(res.status, 400, email);
    assert.deepEqual(await res.json(), { status: 'invalid' });
  }
});

test('pretends to subscribe bots that fill the honeypot, but stores nothing', async () => {
  const res = await subscribe({ email: 'bot@example.com', website: 'http://spam.example' });
  assert.equal(res.status, 201);
  assert.ok(!(await exported()).includes('"bot@example.com"'));
});

test('answers a form posted without JavaScript with a page', async () => {
  const res = await subscribe({ email: 'nojs@example.com' }, { json: false });
  assert.equal(res.status, 201);
  assert.match(res.headers.get('content-type'), /text\/html/);
  assert.match(await res.text(), /on the list/);
});

test('rate limits one address after five attempts', async () => {
  const statuses = [];
  for (let i = 0; i < 6; i++) statuses.push((await subscribe({ email: `burst${i}@example.com` }, { from: '10.9.9.9' })).status);
  assert.deepEqual(statuses, [201, 201, 201, 201, 201, 429]);
});

test('only accepts POST on the subscribe endpoint', async () => {
  assert.equal((await fetch(`${base}/api/subscribe`)).status, 405);
});

test('hides the export without the right token', async () => {
  assert.equal((await fetch(`${base}/api/export.csv`)).status, 404);
  const wrong = await fetch(`${base}/api/export.csv`, { headers: { Authorization: 'Bearer wrong' } });
  assert.equal(wrong.status, 404);
});

test('escapes quotes and commas in the export', async () => {
  await subscribe({ email: '"a,b"@example.com' });
  const res = await fetch(`${base}/api/export.csv`, { headers: { Authorization: `Bearer ${TOKEN}` } });
  assert.match(await res.text(), /^"""a,b""@example.com",/m);
});

test('keeps the list across a restart, as across a deploy', async () => {
  await subscribe({ email: 'survivor@example.com' });
  await stop(server);
  ({ child: server, base } = await start());
  assert.ok((await exported()).includes('"survivor@example.com"'));
});
