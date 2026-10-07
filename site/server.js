// Serves the landing page and stores waitlist signups in SQLite.
// Railway runs this with `site/` as the service root and a volume attached; it sets
// RAILWAY_VOLUME_MOUNT_PATH to where the volume is mounted. Locally the database sits next to this file.

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');

const PORT = Number(process.env.PORT) || 3000;
const EXPORT_TOKEN = process.env.EXPORT_TOKEN || '';

const db = new DatabaseSync(path.join(process.env.RAILWAY_VOLUME_MOUNT_PATH || __dirname, 'waitlist.db'));
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS subscribers (
    email TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  );
`);
const insert = db.prepare('INSERT INTO subscribers (email) VALUES (?) ON CONFLICT (email) DO NOTHING');
const all = db.prepare('SELECT email, created_at FROM subscribers ORDER BY created_at');

// ---------- Static files ----------
// Only these are public, so server.js, package.json and node_modules never are.

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
};

const PUBLIC = ['index.html', 'main.js', 'style.css', 'favicon.svg',
  ...fs.readdirSync(path.join(__dirname, 'fonts')).map(f => `fonts/${f}`)];

const files = new Map(PUBLIC.map(name => [
  name === 'index.html' ? '/' : `/${name}`,
  {
    body: fs.readFileSync(path.join(__dirname, name)),
    type: TYPES[path.extname(name)],
    // Font names never change; everything else is revalidated so a deploy shows up at once.
    cache: name.startsWith('fonts/') ? 'public, max-age=31536000, immutable' : 'no-cache',
  },
]));

// ---------- Waitlist ----------

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Five attempts per address per ten minutes, kept in memory: one instance, and a restart
// forgetting the counts is harmless.
const WINDOW_MS = 10 * 60 * 1000;
const MAX_ATTEMPTS = 5;
const attempts = new Map();

function limited(ip) {
  const now = Date.now();
  const recent = (attempts.get(ip) || []).filter(t => now - t < WINDOW_MS);
  recent.push(now);
  attempts.set(ip, recent);
  return recent.length > MAX_ATTEMPTS;
}

setInterval(() => {
  const now = Date.now();
  for (const [ip, times] of attempts) {
    if (times.every(t => now - t >= WINDOW_MS)) attempts.delete(ip);
  }
}, WINDOW_MS).unref();

function readBody(req, limit = 2048) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', chunk => {
      body += chunk;
      if (body.length > limit) { reject(new Error('too large')); req.destroy(); }
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

async function subscribe(req, res) {
  // Without JavaScript the browser posts the form and expects a page back, not JSON.
  const wantsJson = (req.headers.accept || '').includes('application/json');
  const reply = (code, status, message) => {
    if (wantsJson) {
      res.writeHead(code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status }));
    } else {
      res.writeHead(code, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(`<!doctype html><meta charset="utf-8"><title>Vishot</title><p>${message}</p><p><a href="/">← Back to vishot.dev</a></p>`);
    }
  };

  const ip = (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || req.socket.remoteAddress;
  if (limited(ip)) return reply(429, 'rate_limited', 'Too many attempts. Try again in a few minutes.');

  let fields;
  try {
    fields = new URLSearchParams(await readBody(req));
  } catch {
    return reply(413, 'invalid', "That doesn't look like an email address.");
  }

  // Honeypot: people never see the `website` field, form-filling bots do. Pretend it worked.
  if (fields.get('website')) return reply(201, 'subscribed', "You're on the list.");

  const email = (fields.get('email') || '').trim().toLowerCase();
  if (email.length > 254 || !EMAIL.test(email)) {
    return reply(400, 'invalid', "That doesn't look like an email address.");
  }

  try {
    if (insert.run(email).changes) reply(201, 'subscribed', "You're on the list. We'll write when the beta opens.");
    else reply(200, 'already', "You're already on the list.");
  } catch (err) {
    console.error('subscribe failed:', err.message);
    reply(500, 'error', "That didn't go through. Try again in a moment.");
  }
}

// The whole list as CSV, for `curl -H "Authorization: Bearer $EXPORT_TOKEN"`. Off unless EXPORT_TOKEN is set.
function exportCsv(req, res) {
  const given = Buffer.from((req.headers.authorization || '').replace(/^Bearer /, ''));
  const expected = Buffer.from(EXPORT_TOKEN);
  if (!EXPORT_TOKEN || given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('Not found');
  }
  // Emails were validated to have no whitespace, but may still contain commas or quotes.
  const quote = s => `"${s.replaceAll('"', '""')}"`;
  const rows = all.all().map(r => `${quote(r.email)},${r.created_at}`);
  res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(['email,created_at', ...rows].join('\n') + '\n');
}

// ---------- Server ----------

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  res.setHeader('X-Content-Type-Options', 'nosniff');

  // www.vishot.dev points here too; send it to the one canonical address.
  const host = req.headers.host || '';
  if (host.startsWith('www.')) {
    res.writeHead(301, { Location: `https://${host.slice(4)}${url.pathname}${url.search}` });
    return res.end();
  }

  if (url.pathname === '/api/subscribe') {
    if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
    return subscribe(req, res);
  }

  if (url.pathname === '/api/export.csv' && req.method === 'GET') return exportCsv(req, res);

  if (url.pathname === '/healthz') { res.writeHead(200); return res.end('ok'); }

  const file = files.get(url.pathname);
  if (!file || (req.method !== 'GET' && req.method !== 'HEAD')) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('Not found');
  }
  res.writeHead(200, { 'Content-Type': file.type, 'Cache-Control': file.cache });
  res.end(req.method === 'HEAD' ? undefined : file.body);
});

server.listen(PORT, () => console.log(`listening on ${server.address().port}`));

// Railway sends SIGTERM before swapping in a new deploy; close the database so the WAL is checkpointed.
process.on('SIGTERM', () => {
  server.close(() => { db.close(); process.exit(0); });
});
