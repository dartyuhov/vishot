// Serves the landing page and cached public release metadata without persistent storage.

'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { createMetadata } = require('./metadata');
const metadata = createMetadata();

// PORT=0 means "any free port", which the tests use, so don't treat it as unset.
const PORT = process.env.PORT ? Number(process.env.PORT) : 3000;

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

// Railway sends SIGTERM before swapping in a new deploy; finish active HTTP requests.
process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});
