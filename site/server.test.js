// Runs server.js as Railway would, against throwaway volume directories. `npm test`.

'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const TOKEN = 'test-export-token';
const volume = fs.mkdtempSync(path.join(os.tmpdir(), 'vishot-waitlist-'));
const records = [
  ['survivor@example.com', '2026-10-01T12:00:00Z', 'Web pages', 'reddit'],
  ['veteran@example.com', '2026-10-02T12:00:00Z', null, null],
  ['"a,b"@example.com', '2026-10-03T12:00:00Z', 'Other: charts, "slides"', '=HYPERLINK("x")'],
  ['plus@example.com', '2026-10-04T12:00:00Z', null, '+source'],
  ['minus@example.com', '2026-10-05T12:00:00Z', null, '-source'],
  ['at@example.com', '2026-10-06T12:00:00Z', null, '@source'],
];
const expectedCsv = `email,created_at,use_case,source
"survivor@example.com",2026-10-01T12:00:00Z,"Web pages","reddit"
"veteran@example.com",2026-10-02T12:00:00Z,,
"""a,b""@example.com",2026-10-03T12:00:00Z,"Other: charts, ""slides""","'=HYPERLINK(""x"")"
"plus@example.com",2026-10-04T12:00:00Z,,"'+source"
"minus@example.com",2026-10-05T12:00:00Z,,"'-source"
"at@example.com",2026-10-06T12:00:00Z,,"'@source"
`;
let server;
let base;

function start({ directory = volume, token = TOKEN } = {}) {
  const child = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    env: { ...process.env, PORT: '0', RAILWAY_VOLUME_MOUNT_PATH: directory, EXPORT_TOKEN: token },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  return new Promise((resolve, reject) => {
    child.stdout.on('data', chunk => {
      const port = /listening on (\d+)/.exec(chunk)?.[1];
      if (port) resolve({ child, base: `http://127.0.0.1:${port}` });
    });
    child.on('error', reject);
    child.on('exit', code => reject(new Error(`server exited with ${code}`)));
  });
}

function stop(child) {
  if (child.exitCode !== null) return Promise.resolve();
  return new Promise(resolve => { child.on('exit', resolve); child.kill('SIGTERM'); });
}

function exported(address = base) {
  return fetch(`${address}/api/export.csv`, { headers: { Authorization: `Bearer ${TOKEN}` } });
}

before(async () => {
  // Fixture setup only: verify records through the authenticated HTTP export, never SQL.
  const db = new DatabaseSync(path.join(volume, 'waitlist.db'));
  db.exec(`CREATE TABLE subscribers (email TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    use_case TEXT, source TEXT);`);
  const insert = db.prepare('INSERT INTO subscribers VALUES (?, ?, ?, ?)');
  for (const record of records) insert.run(...record);
  db.close();
  ({ child: server, base } = await start());
});
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
    assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(res.headers.get('cache-control'), url.startsWith('/fonts/')
      ? 'public, max-age=31536000, immutable' : 'no-cache');
    assert.ok((await res.arrayBuffer()).byteLength > 0, url);
    const head = await fetch(base + url, { method: 'HEAD' });
    assert.equal(head.status, 200, url);
    assert.equal(await head.text(), '');
  }
});

test('loads nothing from YouTube until the demo video is asked for', async () => {
  const html = await (await fetch(base + '/')).text();
  // A canonical link names the page; it isn't something the browser fetches.
  assert.ok(!/<iframe|youtube-nocookie|<(script|img)[^>]+src="https?:|<link(?![^>]*rel="canonical")[^>]+href="https?:/i.test(html));
});

test('serves a signup-free page and browser bundle with working local navigation', async () => {
  const html = await (await fetch(base + '/')).text();
  assert.doesNotMatch(html, /<form\b|<input\b[^>]*(?:type="email"|name="(?:email|use_other|website)")|<select\b/i);
  assert.doesNotMatch(html, /waitlist|sign[ -]?up|get early access|when the beta opens|notify you once/i);
  const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]));
  for (const [, id] of html.matchAll(/href="#([^"]+)"/g)) assert.ok(ids.has(id), `missing anchor ${id}`);
  for (const [, src] of html.matchAll(/<script\b[^>]*src="([^"]+)"/g)) {
    const res = await fetch(new URL(src, base));
    assert.equal(res.status, 200);
    const script = await res.text();
    assert.doesNotMatch(script, /\/api\/subscribe|new FormData\b|name="email"|location\.search|waitlist/i);
  }
});

test('keeps server files and subscriber storage private, even with export credentials', async () => {
  for (const url of ['/server.js', '/server.test.js', '/package.json', '/package-lock.json',
    '/waitlist.db', '/waitlist.db-wal', '/waitlist.db-shm', '/../server.js', '/node_modules/',
    '/fonts/../waitlist.db', '/fonts/%2e%2e%2fwaitlist.db', '/.env', '/not-public']) {
    for (const method of ['GET', 'HEAD']) {
      const res = await fetch(base + url, { method, headers: { Authorization: `Bearer ${TOKEN}` } });
      assert.equal(res.status, 404, `${method} ${url}`);
    }
  }
  assert.equal((await fetch(base + '/main.js', { method: 'POST', body: 'no' })).status, 404);
});

test('keeps the health check available', async () => {
  const res = await fetch(base + '/healthz');
  assert.equal(res.status, 200);
  assert.equal(await res.text(), 'ok');
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

test('retires public intake for old browsers and API clients without adding or updating records', async () => {
  for (const accept of ['application/json', 'text/html']) {
    for (const email of ['new@example.com', 'veteran@example.com', 'survivor@example.com']) {
      const res = await fetch(`${base}/api/subscribe?ref=old-link`, {
        method: 'POST', headers: { Accept: accept },
        body: new URLSearchParams({ email, use: 'Whole screen', ref: 'new-source' }),
      });
      assert.equal(res.status, 404);
      assert.equal(await res.text(), 'Not found');
      assert.equal(await (await exported()).text(), expectedCsv);
    }
  }
  for (const method of ['GET', 'HEAD', 'PUT', 'OPTIONS']) {
    assert.equal((await fetch(`${base}/api/subscribe`, { method })).status, 404, method);
  }
});

test('exports existing records with CSV escaping and spreadsheet-safe sources', async () => {
  const res = await exported();
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'text/csv; charset=utf-8');
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(await res.text(), expectedCsv);
});

test('hides the export without the right token and never accepts writes', async () => {
  for (const authorization of ['', 'Bearer wrong', `Bearer ${'x'.repeat(TOKEN.length)}`]) {
    const res = await fetch(`${base}/api/export.csv`, { headers: { Authorization: authorization } });
    assert.equal(res.status, 404);
    assert.equal(await res.text(), 'Not found');
  }
  for (const method of ['POST', 'PUT', 'DELETE', 'HEAD']) {
    const res = await fetch(`${base}/api/export.csv`, { method, headers: { Authorization: `Bearer ${TOKEN}` } });
    assert.equal(res.status, 404, method);
  }
});

test('disables export when EXPORT_TOKEN is unset', async () => {
  const disabled = await start({ token: '' });
  try {
    const res = await exported(disabled.base);
    assert.equal(res.status, 404);
    assert.equal((await fetch(disabled.base + '/healthz')).status, 200);
  } finally {
    await stop(disabled.child);
  }
});

// Start old schemas as Railway would, with people already on the list.
test('preserves legacy records from before optional answer and source columns existed', async () => {
  for (const columns of ['', ', use_case TEXT']) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vishot-old-'));
    let legacy;
    try {
      const db = new DatabaseSync(path.join(directory, 'waitlist.db'));
      db.exec(`CREATE TABLE subscribers (email TEXT PRIMARY KEY, created_at TEXT NOT NULL${columns});`);
      db.prepare('INSERT INTO subscribers (email, created_at) VALUES (?, ?)')
        .run('veteran@example.com', '2026-10-01T12:00:00Z');
      db.close();
      legacy = await start({ directory });
      const res = await exported(legacy.base);
      assert.equal(res.status, 200);
      assert.equal(await res.text(), 'email,created_at,use_case,source\n"veteran@example.com",2026-10-01T12:00:00Z,,\n');
    } finally {
      if (legacy) await stop(legacy.child);
      fs.rmSync(directory, { recursive: true, force: true });
    }
  }
});

test('keeps existing records unchanged across a restart, as across a deploy', async () => {
  await stop(server);
  ({ child: server, base } = await start());
  assert.equal(await (await exported()).text(), expectedCsv);
});
