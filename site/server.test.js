// Runs server.js as Railway would, against a throwaway volume directory. `npm test`.

'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
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
  if (child.exitCode !== null) return Promise.resolve();
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

// The export row for one address, after the email: [created_at, use_case, source].
async function rowFor(email) {
  const res = await fetch(`${base}/api/export.csv`, { headers: { Authorization: `Bearer ${TOKEN}` } });
  const line = (await res.text()).split('\n').find(l => l.startsWith(`"${email}"`));
  return line && line.slice(email.length + 3).split(',').map(c => c.replace(/^"|"$/g, '').replaceAll('""', '"'));
}

before(async () => ({ child: server, base } = await start()));
after(async () => {
  if (server) await stop(server);
  fs.rmSync(volume, { recursive: true, force: true });
});

test('serves the landing page and its assets', async () => {
  for (const [url, type] of [['/', 'text/html'], ['/main.js', 'text/javascript'], ['/style.css', 'text/css'],
    ['/favicon.svg', 'image/svg+xml'], ['/og.png', 'image/png'], ['/fonts/silkscreen-latin-400-normal.woff2', 'font/woff2']]) {
    const res = await fetch(base + url);
    assert.equal(res.status, 200, url);
    assert.ok(res.headers.get('content-type').startsWith(type), url);
  }
});

test('loads nothing from YouTube until the demo video is asked for', async () => {
  const html = await (await fetch(base + '/')).text();
  // A canonical link names the page; it isn't something the browser fetches.
  assert.ok(!/<iframe|youtube-nocookie|<(script|img)[^>]+src="https?:|<link(?![^>]*rel="canonical")[^>]+href="https?:/i.test(html));
});

test('keeps server files and the database private', async () => {
  for (const url of ['/server.js', '/server.test.js', '/package.json', '/waitlist.db', '/../server.js', '/node_modules/']) {
    assert.equal((await fetch(base + url)).status, 404, url);
  }
});

test('redirects www to the bare domain', async () => {
  const { status, location } = await new Promise((resolve, reject) => {
    http.get(`${base}/some/page?x=1`, { headers: { Host: 'www.vishot.dev' } }, res => {
      res.resume();
      resolve({ status: res.statusCode, location: res.headers.location });
    }).on('error', reject);
  });
  assert.equal(status, 301);
  assert.equal(location, 'https://vishot.dev/some/page?x=1');
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

test('stores what a new subscriber screenshots most', async () => {
  const res = await subscribe({ email: 'uses-docs@example.com', use: 'Web pages' });
  assert.equal(res.status, 201);
  assert.equal((await rowFor('uses-docs@example.com'))[1], 'Web pages');
});

test('keeps what "Other" says, trimmed and prefixed', async () => {
  await subscribe({ email: 'uses-other@example.com', use: 'Other', use_other: '  =HYPERLINK("x")\n  in   slides ' });
  assert.equal((await rowFor('uses-other@example.com'))[1], 'Other: =HYPERLINK("x") in slides');
  await subscribe({ email: 'uses-other-empty@example.com', use: 'Other', use_other: '   ' });
  assert.equal((await rowFor('uses-other-empty@example.com'))[1], 'Other');
});

test('drops an answer that is not in the dropdown, without failing the sign-up', async () => {
  const res = await subscribe({ email: 'uses-junk@example.com', use: '<script>alert(1)</script>' });
  assert.equal(res.status, 201);
  assert.equal((await rowFor('uses-junk@example.com'))[1], '');
});

test('lets someone already on the list answer once, but never replaces the answer', async () => {
  await subscribe({ email: 'late@example.com' });
  await subscribe({ email: 'late@example.com', use: 'Bugs and errors' });
  await subscribe({ email: 'late@example.com', use: 'Web pages' });
  assert.equal((await rowFor('late@example.com'))[1], 'Bugs and errors');
});

test('accepts every choice the form offers', async () => {
  const html = await (await fetch(base + '/')).text();
  const choices = [...new Set([...html.matchAll(/<option>([^<]+)<\/option>/g)].map(m => m[1]))];
  assert.ok(choices.length >= 2);
  for (const [i, use] of choices.entries()) {
    await subscribe({ email: `choice-${i}@example.com`, use });
    assert.equal((await rowFor(`choice-${i}@example.com`))[1].split(':')[0], use, use);
  }
});

test('stores which link a new subscriber came from', async () => {
  await subscribe({ email: 'from-reddit@example.com', ref: '  Reddit-MacApps ' });
  assert.equal((await rowFor('from-reddit@example.com'))[2], 'reddit-macapps');
});

test('keeps any short text as the source, tidied', async () => {
  const cases = [['r/macapps post', 'R/MacApps   post'], ['show hn', 'Show HN'], ['reddit_macapps.v2', 'reddit_macapps.v2'],
    ['two lines', 'two\nlines'], ['ü-ref', 'Ü-Ref'], ['a'.repeat(64), 'a'.repeat(100)]];
  for (const [i, [expected, ref]] of cases.entries()) {
    const res = await subscribe({ email: `any-ref-${i}@example.com`, ref });
    assert.equal(res.status, 201, ref);
    assert.equal((await rowFor(`any-ref-${i}@example.com`))[2], expected, ref);
  }
});

test('stores no source for an empty or blank one, without failing the sign-up', async () => {
  for (const [i, ref] of ['', '   ', '\n\t'].entries()) {
    const res = await subscribe({ email: `blank-ref-${i}@example.com`, ref });
    assert.equal(res.status, 201);
    assert.equal((await rowFor(`blank-ref-${i}@example.com`))[2], '');
  }
});

test('stops a source from reading as a formula, or breaking the export', async () => {
  await subscribe({ email: 'formula@example.com', ref: '=HYPERLINK("x")' });
  assert.equal((await rowFor('formula@example.com'))[2], "'=hyperlink(\"x\")");
  await subscribe({ email: 'commas@example.com', ref: 'a, b "c"' });
  const res = await fetch(`${base}/api/export.csv`, { headers: { Authorization: `Bearer ${TOKEN}` } });
  assert.match(await res.text(), /^"commas@example.com",[^,]+,,"a, b ""c"""$/m);
});

test('lets someone already on the list get a source once, but never replaces it', async () => {
  await subscribe({ email: 'again@example.com', use: 'Web pages' });
  await subscribe({ email: 'again@example.com', ref: 'youtube' });
  await subscribe({ email: 'again@example.com', ref: 'x', use: 'Whole screen' });
  assert.deepEqual((await rowFor('again@example.com')).slice(1), ['Web pages', 'youtube']);
});

// A database from before the columns existed (or with only the first of them), started as Railway
// would start it: the columns appear, and the people already on the list stay.
async function exportFromLegacy(columns) {
  const { DatabaseSync } = require('node:sqlite');
  const old = fs.mkdtempSync(path.join(os.tmpdir(), 'vishot-old-'));
  const legacy = new DatabaseSync(path.join(old, 'waitlist.db'));
  legacy.exec(`CREATE TABLE subscribers (email TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))${columns});
    INSERT INTO subscribers (email) VALUES ('veteran@example.com');`);
  legacy.close();
  const child = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    env: { ...process.env, PORT: '0', RAILWAY_VOLUME_MOUNT_PATH: old, EXPORT_TOKEN: TOKEN },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  try {
    const port = await new Promise((resolve, reject) => {
      child.stdout.on('data', c => { const p = /listening on (\d+)/.exec(c)?.[1]; if (p) resolve(p); });
      child.on('exit', code => reject(new Error(`server exited with ${code}`)));
    });
    const res = await fetch(`http://127.0.0.1:${port}/api/export.csv`, { headers: { Authorization: `Bearer ${TOKEN}` } });
    return await res.text();
  } finally {
    await stop(child);
    fs.rmSync(old, { recursive: true, force: true });
  }
}

test('adds the answer and source columns to a database made before they existed', async () => {
  const row = /^email,created_at,use_case,source\n"veteran@example.com",[^,]+,,\n$/;
  assert.match(await exportFromLegacy(''), row);
  assert.match(await exportFromLegacy(', use_case TEXT'), row);
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
