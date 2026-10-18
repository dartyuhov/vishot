'use strict';

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
        const version = /^v?(\d+\.\d+\.\d+)$/.exec(release.tag_name)?.[1];
        if (!version || release.draft !== false || release.prerelease !== false || !release.published_at ||
          release.html_url !== `${REPOSITORY}/releases/tag/${release.tag_name}`) continue;
        const links = {};
        for (const arch of ['arm64', 'x86_64']) {
          const name = `Vishot-${version}-${arch}.dmg`;
          const assets = (release.assets || []).filter(asset => asset.name === name && asset.state === 'uploaded' && asset.size > 0 &&
            asset.browser_download_url === `${REPOSITORY}/releases/download/${release.tag_name}/${name}`);
          if (assets.length === 1) links[arch] = assets[0].browser_download_url;
        }
        if (links.arm64 && links.x86_64) {
          complete = { ready: true, version, command: COMMAND, release: release.html_url, ...links };
          break;
        }
      }
      if (releases.length < 100) break;
    }
    if (!complete || file.type !== 'file' || file.encoding !== 'base64') return { ready: false };
    const cask = Buffer.from(file.content, 'base64').toString('utf8');
    // Verify the owned public cask targets this exact release and both architectures. The
    // explicit launch switch still requires the installation/hardware checks in ticket .6.
    if (!cask.includes(`version "${complete.version}"`) ||
      !/arch\s+arm:\s*"arm64",\s*intel:\s*"x86_64"/.test(cask) ||
      !/sha256\s+arm:\s*"[a-f0-9]{64}",\s*intel:\s*"[a-f0-9]{64}"/.test(cask) ||
      !cask.includes(`url "${REPOSITORY}/releases/download/v#{version}/Vishot-#{version}-#{arch}.dmg"`) ||
      !cask.includes('depends_on macos: ">= :sonoma"') || !cask.includes('app "Vishot.app"')) return { ready: false };
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
      if (!value.ready) return html;
      return html.replace('data-install-controls hidden', 'data-install-controls')
        .replace('data-install-status>', 'data-install-status hidden>')
        .replace('data-brew-command></code>', `data-brew-command>${COMMAND}</code>`)
        .replace('data-arm64 href="/download"', `data-arm64 href="${value.arm64}"`)
        .replace('data-x86-64 href="/download"', `data-x86-64 href="${value.x86_64}"`);
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
