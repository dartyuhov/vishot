// Local controlled-metadata preview for installer browser checks. Never allowlisted by server.js.
'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { createMetadata } = require('../metadata');
const version = '0.2.0';
const repo = 'https://github.com/dartyuhov/vishot';
const cask = `cask "vishot" do
  arch arm: "arm64", intel: "x86_64"
  version "0.2.0"
  sha256 arm: "${'a'.repeat(64)}", intel: "${'b'.repeat(64)}"
  url "${repo}/releases/download/v#{version}/Vishot-#{version}-#{arch}.dmg"
  depends_on macos: ">= :sonoma"
  app "Vishot.app"
end`;
const metadata = createMetadata({ enabled: true, fetch: async url => {
  const route = new URL(url).pathname;
  let value;
  if (route.endsWith('/releases')) value = [{ tag_name: `v${version}`, draft: false, prerelease: false,
    published_at: '2026-10-18T12:00:00Z', html_url: `${repo}/releases/tag/v${version}`,
    assets: ['arm64', 'x86_64'].map(arch => ({ name: `Vishot-${version}-${arch}.dmg`, state: 'uploaded', size: 1234,
      browser_download_url: `${repo}/releases/download/v${version}/Vishot-${version}-${arch}.dmg` })) }];
  else if (route.endsWith('/Casks/vishot.rb')) value = { type: 'file', encoding: 'base64', content: Buffer.from(cask).toString('base64') };
  else value = { private: false, visibility: 'public', owner: { login: 'dartyuhov' }, stargazers_count: 42 };
  return new Response(JSON.stringify(value));
} });
const root = path.join(__dirname, '..');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.woff2': 'font/woff2' };
http.createServer(async (req, res) => {
  if (await metadata.handle(req, res)) return;
  const name = new URL(req.url, 'http://localhost').pathname.slice(1) || 'index.html';
  if (!['index.html', 'main.js', 'install.js', 'style.css', 'favicon.svg', ...fs.readdirSync(path.join(root, 'fonts')).map(f => `fonts/${f}`)].includes(name)) {
    res.writeHead(404); return res.end();
  }
  res.setHeader('Content-Type', types[path.extname(name)]);
  const body = fs.readFileSync(path.join(root, name));
  res.end(name === 'index.html' ? await metadata.page(body.toString()) : body);
}).listen(3107, '127.0.0.1', () => console.log('Controlled installer preview: http://127.0.0.1:3107'));
