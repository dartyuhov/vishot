// Serves the landing page and retains authenticated export of existing subscribers.
// Railway runs this with `site/` as the service root and a volume attached; it sets
// RAILWAY_VOLUME_MOUNT_PATH to where the volume is mounted. Locally the database sits next to this file.

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const { createMetadata } = require('./metadata');
const metadata = createMetadata();

// PORT=0 means "any free port", which the tests use, so don't treat it as unset.
const PORT = process.env.PORT ? Number(process.env.PORT) : 3000;
const EXPORT_TOKEN = process.env.EXPORT_TOKEN || '';

// Keep the existing location and schema: signup retirement must not discard records.
const db = new DatabaseSync(path.join(process.env.RAILWAY_VOLUME_MOUNT_PATH || __dirname, 'waitlist.db'));
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS subscribers (
    email TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  );
`);
// Preserve export compatibility with databases predating these optional columns.
for (const column of ['use_case', 'source']) {
  if (!db.prepare("SELECT 1 FROM pragma_table_info('subscribers') WHERE name = ?").get(column)) {
    db.exec(`ALTER TABLE subscribers ADD COLUMN ${column} TEXT`);
  }
}
const all = db.prepare('SELECT email, created_at, use_case, source FROM subscribers ORDER BY created_at');

// ---------- Static files ----------
// Only these are public, so server.js, package.json and node_modules never are.

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
};

const PUBLIC = ['index.html', 'main.js', 'install.js', 'style.css', 'favicon.svg', 'og.png',
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

// ---------- Retained subscriber export ----------
// Off unless EXPORT_TOKEN is set. Public subscription intake has been retired.
function exportCsv(req, res) {
  const given = Buffer.from((req.headers.authorization || '').replace(/^Bearer /, ''));
  const expected = Buffer.from(EXPORT_TOKEN);
  if (!EXPORT_TOKEN || given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('Not found');
  }
  // Emails and answers may contain commas or quotes. Sources came from arbitrary
  // referral links, so defuse leading spreadsheet formula characters as well.
  const quote = s => `"${s.replaceAll('"', '""')}"`;
  const safe = s => (/^[=+\-@]/.test(s) ? `'${s}` : s);
  const rows = all.all().map(r => `${quote(r.email)},${r.created_at},${r.use_case ? quote(r.use_case) : ''},${r.source ? quote(safe(r.source)) : ''}`);
  res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(['email,created_at,use_case,source', ...rows].join('\n') + '\n');
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

  if (url.pathname === '/api/export.csv' && req.method === 'GET') return exportCsv(req, res);

  if (url.pathname === '/healthz') { res.writeHead(200); return res.end('ok'); }

  if (await metadata.handle(req, res)) return;

  const file = files.get(url.pathname);
  if (!file || (req.method !== 'GET' && req.method !== 'HEAD')) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('Not found');
  }
  res.writeHead(200, { 'Content-Type': file.type, 'Cache-Control': file.cache });
  const body = url.pathname === '/' && req.method === 'GET' ? await metadata.page(file.body.toString()) : file.body;
  res.end(req.method === 'HEAD' ? undefined : body);
});

server.listen(PORT, () => console.log(`listening on ${server.address().port}`));

// Railway sends SIGTERM before swapping in a new deploy; close the database so the WAL is checkpointed.
process.on('SIGTERM', () => {
  server.close(() => { db.close(); process.exit(0); });
});
