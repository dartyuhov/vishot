'use strict';

const { architectures, regular, hash, check, names, validateManifest } = require('./release-contract');

const REPOSITORY = 'https://github.com/dartyuhov/vishot';
const COMMAND = 'brew install --cask dartyuhov/tap/vishot';

// VISHOT_INSTALL_READY=true is an operator attestation that the launch/hardware checks
// passed. It is necessary but never sufficient: public release and tap checks still apply.
function createMetadata({ enabled = process.env.VISHOT_INSTALL_READY === 'true',
  fetch: request = globalThis.fetch, now = Date.now } = {}) {
  async function github(route) {
    const response = await request(`https://api.github.com/repos/dartyuhov/${route}`, {
      headers: { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'vishot-site' },
      signal: AbortSignal.timeout(4000),
    });
    if (!response.ok) throw new Error('Public metadata unavailable');
    return response.json();
  }

  const isPublic = repo => repo.private === false && repo.visibility === 'public';
  async function verifyRelease(release, version) {
    const expected = names(version);
    const assets = release.assets;
    if (!Array.isArray(assets) || assets.length !== expected.length || !expected.every(name =>
      assets.filter(a => a.name === name && a.state === 'uploaded' && Number.isSafeInteger(a.size) && a.size > 0 &&
        a.browser_download_url === `${REPOSITORY}/releases/download/${release.tag_name}/${name}` &&
        /^sha256:[a-f0-9]{64}$/.test(a.digest)).length === 1)) return;
    const commit = await github(`vishot/commits/${release.tag_name}`);
    check(/^[a-f0-9]{40}$/.test(commit.sha), 'Invalid source commit');
    const lock = await github(`vishot/contents/Package.resolved?ref=${commit.sha}`);
    check(lock.encoding === 'base64' && typeof lock.content === 'string', 'Missing lockfile');
    const lockHash = hash(Buffer.from(lock.content, 'base64'));
    async function sidecar(asset) {
      check(asset.size <= 16384, 'Oversized sidecar');
      const response = await request(asset.browser_download_url, { signal: AbortSignal.timeout(4000) });
      check(response.ok, 'Sidecar unavailable');
      // Bound reads as well as declared metadata; never buffer a DMG here.
      const chunks = [];
      let size = 0;
      for await (const chunk of response.body) {
        size += chunk.length;
        check(size <= 16384, 'Oversized sidecar response');
        chunks.push(chunk);
      }
      const bytes = Buffer.concat(chunks);
      check(bytes.length === asset.size && `sha256:${hash(bytes)}` === asset.digest, 'Sidecar digest/size mismatch');
      return bytes.toString('utf8');
    }
    const links = {}, digests = {};
    await Promise.all(architectures.map(async architecture => {
      const asset = `Vishot-${version}-${architecture}.dmg`;
      const dmg = assets.find(a => a.name === asset);
      const digest = dmg.digest.slice(7);
      const [checksum, manifest] = await Promise.all(['.sha256', '.json'].map(suffix =>
        sidecar(assets.find(a => a.name === asset + suffix))));
      check(checksum === `${digest}  ${asset}\n`, 'Checksum mismatch');
      validateManifest(JSON.parse(manifest), { asset, architecture, version, digest, source: commit.sha, lockHash });
      links[architecture] = dmg.browser_download_url;
      digests[architecture] = digest;
    }));
    return { links, digests };
  }
  async function installation() {
    if (!enabled) return { ready: false };
    const [repo, tap, file] = await Promise.all([
      github('vishot'), github('homebrew-tap'), github('homebrew-tap/contents/Casks/vishot.rb'),
    ]);
    if (!isPublic(repo) || !isPublic(tap) || tap.owner?.login !== 'dartyuhov') return { ready: false };
    // Bound pagination. If a complete release cannot be found, fail closed rather than guess.
    let complete;
    for (let page = 1; page <= 10 && !complete; page++) {
      const releases = await github(`vishot/releases?per_page=100&page=${page}`);
      if (!Array.isArray(releases)) throw new Error('Invalid releases');
      for (const release of releases) {
        const version = typeof release.tag_name === 'string' && release.tag_name.startsWith('v') ? release.tag_name.slice(1) : '';
        if (!regular.test(version) || release.draft !== false || release.prerelease !== false || !release.published_at ||
          release.html_url !== `${REPOSITORY}/releases/tag/${release.tag_name}`) continue;
        const verified = await verifyRelease(release, version);
        if (verified) {
          complete = { ready: true, version, command: COMMAND, release: release.html_url, ...verified.links };
          complete.digests = verified.digests;
          break;
        }
      }
      if (releases.length < 100) break;
    }
    if (!complete || file.type !== 'file' || file.encoding !== 'base64') return { ready: false };
    const cask = Buffer.from(file.content, 'base64').toString('utf8');
    // Verify the owned public cask targets this exact release and both architectures. The
    // explicit launch switch still requires the installation/hardware checks in ticket .6.
    const checksums = /^\s*sha256\s+arm:\s*"([a-f0-9]{64})",\s*intel:\s*"([a-f0-9]{64})"\s*$/m.exec(cask);
    if (!checksums || checksums[1] !== complete.digests.arm64 || checksums[2] !== complete.digests.x86_64 ||
      !cask.includes(`version "${complete.version}"`) ||
      !/arch\s+arm:\s*"arm64",\s*intel:\s*"x86_64"/.test(cask) ||
      !cask.includes(`url "${REPOSITORY}/releases/download/v#{version}/Vishot-#{version}-#{arch}.dmg"`) ||
      !cask.includes('depends_on macos: ">= :sonoma"') || !cask.includes('app "Vishot.app"')) return { ready: false };
    delete complete.digests;
    return complete;
  }

  // Separate caches/in-flight requests: optional stars never hold up installation. Failures
  // are cached too, preventing a burst of traffic from exhausting GitHub's public quota.
  // Revalidate after 15 minutes; back off one minute on errors. Only stars may stay stale.
  function cached(load, fallback, stale = false) {
    let value = fallback;
    let until = -1;
    let pending;
    return async () => {
      if (now() < until) return value;
      if (!pending) pending = (async () => {
        try { value = await load(); until = now() + 15 * 60 * 1000; }
        catch { if (!stale) value = fallback; until = now() + 60 * 1000; }
        finally { pending = undefined; }
        return value;
      })();
      return pending;
    };
  }
  const install = cached(installation, { ready: false });
  const stars = cached(async () => {
    const repo = await github('vishot');
    if (!isPublic(repo) || !Number.isSafeInteger(repo.stargazers_count) || repo.stargazers_count < 0) throw new Error('Invalid stars');
    return { stars: repo.stargazers_count };
  }, { stars: null }, true);
  return {
    install,
    async page(html) {
      const value = await install();
      const slots = {
        INSTALL_STATUS: value.ready ? ' hidden' : '',
        INSTALL_CONTROLS: value.ready ? '' : ' hidden',
        BREW_COMMAND: value.ready ? COMMAND : '',
        ARM64_URL: value.ready ? value.arm64 : '/download',
        X86_64_URL: value.ready ? value.x86_64 : '/download',
      };
      // Validate every slot before substituting anything. Template drift must
      // never expose a half-enabled installer or leak unresolved placeholders.
      if (Object.keys(slots).some(key => html.split(`{{${key}}}`).length !== 2) ||
        [...html.matchAll(/{{([^{}]+)}}/g)].some(([, key]) => !Object.hasOwn(slots, key))) {
        return '<!doctype html><html lang="en"><title>Vishot</title><p>Installation temporarily unavailable.</p></html>';
      }
      const escape = text => text.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
      return html.replace(/{{([^{}]+)}}/g, (_, key) => escape(slots[key]));
    },
    async handle(req, res) {
      const route = new URL(req.url, 'http://localhost').pathname;
      if (!['/api/install', '/api/github', '/download'].includes(route)) return false;
      if (!['GET', 'HEAD'].includes(req.method)) {
        res.writeHead(405, { Allow: 'GET, HEAD' }); res.end(); return true;
      }
      const value = await (route === '/api/github' ? stars() : install());
      if (route === '/download') {
        res.writeHead(302, { Location: value.ready ? value.release : '/#install', 'Cache-Control': 'no-store' });
        res.end(); return true;
      }
      res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      res.end(req.method === 'HEAD' ? undefined : JSON.stringify(value));
      return true;
    },
  };
}

module.exports = { createMetadata, REPOSITORY, COMMAND };
