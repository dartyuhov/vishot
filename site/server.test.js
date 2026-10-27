// Exercises the stateless server through HTTP. `npm test`.

'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const TOKEN = 'test-export-token';
let server;
let base;

function start(env = {}) {
  const child = spawn(process.execPath, [path.join(__dirname, 'server.js')], {
    env: { ...process.env, PORT: '0', VISHOT_INSTALL_READY: '', ...env },
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

before(async () => {
  ({ child: server, base } = await start());
});
after(async () => {
  if (server) await stop(server);
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

test('describes history as a release-gated preview', async () => {
  const html = await (await fetch(base + '/')).text();
  assert.match(html, /Capture history/);
  assert.match(html, /History preview: release availability is not yet verified/);
  assert.doesNotMatch(html, /vishot capture --app|agent captures the chat|every key will be remappable/);
  assert.match(html, /Capture History[^]*?<kbd>h<\/kbd><kbd>l<\/kbd>[^]*?<kbd>y<\/kbd>/);
});

test('explains released exact-ID capture and separately labels the annotation preview', async () => {
  const html = await (await fetch(base + '/')).text();
  const card = html.match(/<li id="agent-cli"[^]*?<\/li>/)?.[0];
  const workflow = html.match(/<details id="cli-workflow">[^]*?<\/details>/)?.[0];
  assert.ok(card, 'CLI discovery card');
  assert.ok(workflow, 'CLI workflow FAQ');
  assert.match(card, /capture ships in[^]*?v0\.2\.0/);
  assert.match(card, /Annotation preview \(unreleased\)/);
  assert.match(card, /href="#cli-workflow"/);
  assert.doesNotMatch(html, /Coming soon|Planned command-line capture|Not available yet/);
  assert.match(workflow, /Annotation preview — unreleased, not included in v0\.2\.0/);
  for (const command of [
    '/Applications/Vishot.app/Contents/Helpers/vishot windows',
    '/Applications/Vishot.app/Contents/Helpers/vishot capture --window-id 42',
  ]) assert.ok(workflow.includes(command), `missing bundled command: ${command}`);
  for (const text of ['exact live window ID', 'app and title', 'Screen Recording', 'built-in image reader',
    'capture.path', '.vishot/', 'current workspace', 'same inspected PNG', 'image’s pixels',
    'preserving the original PNG and its pixel dimensions', 'annotation.path', 'Save-only is the default',
    '--open', 'default image app', 'does not prove the image was displayed', 'skill is optional']) {
    assert.ok(workflow.includes(text), `missing workflow guidance: ${text}`);
  }
  assert.match(workflow, /href="https:\/\/github\.com\/dartyuhov\/vishot\/blob\/v0\.2\.0\/docs\/agent-cli\.md"/);
  assert.match(workflow, /href="https:\/\/github\.com\/dartyuhov\/vishot\/blob\/v0\.2\.0\/skills\/vishot-capture\/SKILL\.md"/);
  assert.match(workflow, /href="https:\/\/github\.com\/dartyuhov\/vishot\/blob\/bcae50da04b0ed75aae1f6fe720b51f90b697b20\/docs\/agent-cli\.md#explain-an-interface-from-the-captured-image"/);
  const example = workflow.match(/<code data-cli-annotation>([^]*?)<\/code>/)?.[1];
  assert.ok(example, 'annotation command example');
  assert.match(example, /^vishot annotate --input "\/workspace\/\.vishot\/window-42-example\.png" --annotations '/);
  assert.doesNotMatch(example, /--open|--annotations-file/, 'example is an inline, save-only draft');
  const batch = JSON.parse(example.match(/--annotations '([^]*?)'$/)[1]);
  assert.equal(batch.schemaVersion, 1);
  assert.deepEqual(batch.annotations.map(mark => mark.type), ['rect', 'arrow', 'text']);
  assert.ok(batch.annotations[0].width > 0 && batch.annotations[0].height > 0);
  assert.notDeepEqual(batch.annotations[1].from, batch.annotations[1].to);
  assert.ok(batch.annotations[2].text.trim());
});

test('FAQ explains chip-specific installation, per-app approval and real shortcut configuration', async () => {
  const html = await (await fetch(base + '/')).text();
  const faq = html.split('<div class="faq-list">')[1].split('</section>')[0];
  for (const text of ['Apple Silicon', 'Intel', 'About This Mac', 'Applications', 'eject', 'Open Anyway',
    'Privacy &amp; Security', 'Screen Recording', 'Accessibility', 'brew upgrade --cask', 'capture shortcut']) {
    assert.ok(faq.includes(text), `FAQ missing ${text}`);
  }
  assert.doesNotMatch(faq, /every key will|xattr|spctl|--no-quarantine|disable Gatekeeper/);
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

test('retires public intake for old browsers and API clients', async () => {
  for (const accept of ['application/json', 'text/html']) {
    for (const email of ['new@example.com', 'veteran@example.com', 'survivor@example.com']) {
      const res = await fetch(`${base}/api/subscribe?ref=old-link`, {
        method: 'POST', headers: { Accept: accept },
        body: new URLSearchParams({ email, use: 'Whole screen', ref: 'new-source' }),
      });
      assert.equal(res.status, 404);
      assert.equal(await res.text(), 'Not found');
    }
  }
  for (const method of ['GET', 'HEAD', 'PUT', 'OPTIONS']) {
    assert.equal((await fetch(`${base}/api/subscribe`, { method })).status, 404, method);
  }
});

test('ignores obsolete storage configuration and retires export even with credentials', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vishot-archive-'));
  const archive = Buffer.from('Archived subscriber data: the server must never open or modify this file.');
  fs.writeFileSync(path.join(directory, 'waitlist.db'), archive);
  let instance;
  try {
    instance = await start({ RAILWAY_VOLUME_MOUNT_PATH: directory, EXPORT_TOKEN: TOKEN });
    for (const method of ['GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'OPTIONS']) {
      const response = await fetch(instance.base + '/api/export.csv', {
        method, headers: { Authorization: `Bearer ${TOKEN}` },
      });
      assert.equal(response.status, 404, method);
    }
    assert.equal((await fetch(instance.base + '/healthz')).status, 200);
    await stop(instance.child);
    assert.deepEqual(fs.readdirSync(directory), ['waitlist.db']);
    assert.deepEqual(fs.readFileSync(path.join(directory, 'waitlist.db')), archive);
    instance = await start({ RAILWAY_VOLUME_MOUNT_PATH: path.join(directory, 'missing') });
    assert.equal((await fetch(instance.base + '/healthz')).status, 200);
    assert.deepEqual(fs.readdirSync(directory), ['waitlist.db']);
  } finally {
    if (instance) await stop(instance.child);
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
