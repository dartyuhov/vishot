import { createHash } from 'node:crypto';
import { PullRequestBody } from 'release-please/build/src/util/pull-request-body.js';
import { PullRequestTitle } from 'release-please/build/src/util/pull-request-title.js';
import contract from '../../site/release-contract.js';
const { names, validateManifest } = contract;

const check = (condition, message) => { if (!condition) throw new Error(message); };
const regular = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const fullSha = /^[0-9a-f]{40}$/;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const quiet = { warn() {}, info() {}, debug() {}, error() {}, trace() {} };

// A narrow REST adapter shared by the workflow CLI and controlled-client tests.
// Never retry mutations blindly: an interrupted response may have committed.
export class GitHub {
  constructor({ repo, token, fetch = globalThis.fetch }) {
    check(/^[\w.-]+\/[\w.-]+$/.test(repo), 'Invalid repository');
    this.repo = repo;
    this.token = token;
    this.fetch = fetch;
  }
  async request(path, { method = 'GET', body, binary = false, upload = false } = {}) {
    const url = upload ? path : `https://api.github.com/repos/${this.repo}${path}`;
    if (upload) check(new URL(url).origin === 'https://uploads.github.com', 'Untrusted upload URL');
    const response = await this.fetch(url, {
      method,
      headers: {
        Accept: binary ? 'application/octet-stream' : 'application/vnd.github+json',
        Authorization: `Bearer ${this.token}`,
        'X-GitHub-Api-Version': '2022-11-28',
        ...(body === undefined ? {} : { 'Content-Type': Buffer.isBuffer(body)
          ? 'application/octet-stream' : 'application/json' }),
      },
      ...(body === undefined ? {} : { body: Buffer.isBuffer(body) ? body : JSON.stringify(body) }),
    });
    if (!response.ok) {
      const error = new Error(`GitHub ${method} ${path}: ${response.status}`);
      error.status = response.status;
      throw error;
    }
    if (response.status === 204) return;
    return binary ? Buffer.from(await response.arrayBuffer()) : response.json();
  }
  async optional(path) {
    try { return await this.request(path); } catch (error) {
      if (error.status === 404) return undefined;
      throw error;
    }
  }
  async list(path) {
    const result = [];
    for (let page = 1; ; page++) {
      const rows = await this.request(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`);
      result.push(...rows);
      if (rows.length < 100) return result;
    }
  }
  async file(path, sha) {
    const file = await this.request(`/contents/${path}?ref=${sha}`);
    check(file.encoding === 'base64', `Unsupported content encoding: ${path}`);
    return Buffer.from(file.content, 'base64');
  }
}

export async function approve(api, { sourceSha, prNumber, bot }) {
  check(bot && bot.endsWith('[bot]'), 'Configure the release App bot login');
  let pr;
  if (prNumber) {
    check(/^[1-9]\d*$/.test(String(prNumber)), 'Invalid release PR number');
    pr = await api.request(`/pulls/${prNumber}`);
  } else {
    check(fullSha.test(sourceSha), 'Expected exact push source SHA');
    const prs = await api.list(`/commits/${sourceSha}/pulls`);
    const matches = prs.filter(p => p.merge_commit_sha === sourceSha &&
      p.head?.ref === 'release-please--branches--main' && p.user?.login === bot);
    if (matches.length === 0) return undefined; // Ordinary main merge.
    check(matches.length === 1, 'Ambiguous release approval');
    pr = await api.request(`/pulls/${matches[0].number}`);
  }
  check(pr.merged && pr.merged_at && fullSha.test(pr.merge_commit_sha), 'Release PR must be merged');
  check(!sourceSha || pr.merge_commit_sha === sourceSha, 'Release PR merge differs from push');
  check(pr.user?.login === bot && pr.head?.ref === 'release-please--branches--main' &&
    pr.head.repo?.full_name === api.repo && pr.base?.repo?.full_name === api.repo &&
    pr.base.ref === 'main', 'Not a trusted Release Please PR');
  check(pr.labels.some(l => ['autorelease: pending', 'autorelease: tagged'].includes(l.name)),
    'Release PR lacks lifecycle label');
  const sha = pr.merge_commit_sha;
  const ancestry = await api.request(`/compare/${sha}...main`);
  check(['ahead', 'identical'].includes(ancestry.status), 'Approved commit is not on main');
  const version = (await api.file('version.txt', sha)).toString().trim();
  check(regular.test(version) && version !== '0.0.0', 'Expected a regular release version');
  const title = PullRequestTitle.parse(pr.title, undefined, undefined, quiet);
  const data = PullRequestBody.parse(pr.body ?? '', quiet)?.releaseData;
  check(title?.getVersion()?.toString() === version && data?.length === 1 &&
    data[0].version.toString() === version, 'Release Please PR/version mismatch');
  check(JSON.parse(await api.file('.release-please-manifest.json', sha))['.'] === version,
    'Release manifest/version mismatch');
  const plist = (await api.file('Resources/Info.plist', sha)).toString();
  for (const key of ['CFBundleShortVersionString', 'CFBundleVersion']) {
    check(plist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`))?.[1] === version,
      `Bundle ${key}/version mismatch`);
  }
  return { sha, version, tag: `v${version}`, prNumber: pr.number,
    notes: data[0].notes, bot, pending: pr.labels.some(l => l.name === 'autorelease: pending'),
    lockHash: hash(await api.file('Package.resolved', sha)) };
}

export function validatePackages(files, approval) {
  const expected = names(approval.version);
  check(files.size === expected.length && expected.every(name => files.has(name)), 'Incomplete or unexpected asset set');
  for (const architecture of ['arm64', 'x86_64']) {
    const asset = `Vishot-${approval.version}-${architecture}.dmg`;
    const bytes = files.get(asset);
    check(bytes.length > 0, `Empty installer: ${asset}`);
    const digest = hash(bytes);
    check(files.get(`${asset}.sha256`).toString() === `${digest}  ${asset}\n`, `Checksum mismatch: ${asset}`);
    const manifest = JSON.parse(files.get(`${asset}.json`));
    validateManifest(manifest, { asset, digest, architecture, version: approval.version,
      source: approval.sha, lockHash: approval.lockHash });
  }
}

async function tagCommit(api, tag) {
  let ref = await api.optional(`/git/ref/tags/${tag}`);
  if (!ref) return undefined;
  let object = ref.object;
  for (let depth = 0; object.type === 'tag' && depth < 10; depth++) {
    object = (await api.request(`/git/tags/${object.sha}`)).object;
  }
  check(object.type === 'commit', 'Tag does not resolve to a commit');
  return object.sha;
}

function newer(a, b) {
  const left = a.split('.').map(BigInt), right = b.split('.').map(BigInt);
  for (let i = 0; i < 3; i++) if (left[i] !== right[i]) return left[i] > right[i];
  return false;
}

async function guard(api, approval) {
  const releases = await api.list('/releases');
  for (const release of releases.filter(r => !r.draft && !r.prerelease)) {
    const version = release.tag_name.replace(/^v/, '');
    check(regular.test(version), `Unrecognized regular release: ${release.tag_name}`);
    check(!newer(version, approval.version), 'Stale release run: a newer version is already public');
    if (release.tag_name !== approval.tag) {
      const commit = await tagCommit(api, release.tag_name);
      check(commit, 'Public release tag missing');
      const comparison = await api.request(`/compare/${commit}...${approval.sha}`);
      check(['ahead', 'identical'].includes(comparison.status), 'Release would move source history backward');
    }
  }
  const same = releases.filter(r => r.tag_name === approval.tag);
  check(same.length <= 1, 'Duplicate release tag');
  return same[0];
}

async function remoteFiles(api, release) {
  const assets = await api.list(`/releases/${release.id}/assets`);
  check(new Set(assets.map(a => a.name)).size === assets.length, 'Duplicate remote assets');
  const files = new Map();
  for (const asset of assets) {
    check(asset.state === 'uploaded', `Unfinished asset: ${asset.name}`);
    const bytes = await api.request(`/releases/assets/${asset.id}`, { binary: true });
    check(bytes.length === asset.size, `Remote asset size mismatch: ${asset.name}`);
    files.set(asset.name, bytes);
  }
  return files;
}

export async function publish(api, approval, files) {
  // Re-read authorization instead of trusting a workflow output or stale label.
  const current = await approve(api, { prNumber: approval.prNumber, bot: approval.bot });
  check(current.sha === approval.sha && current.version === approval.version, 'Approval changed');
  approval = current;
  validatePackages(files, approval);
  let release = await guard(api, approval);
  const marker = `<!-- vishot-release pr=${approval.prNumber} sha=${approval.sha} -->`;
  const existingTag = await tagCommit(api, approval.tag);
  check(!existingTag || existingTag === approval.sha, 'Release tag/source mismatch');
  if (release) {
    check(release.body?.includes(marker) && release.target_commitish === approval.sha &&
      !release.prerelease, 'Release identity mismatch');
    if (!release.draft) {
      check(existingTag === approval.sha, 'Public release tag missing');
      validatePackages(await remoteFiles(api, release), approval);
      await finishLabels(api, approval.prNumber);
      return { status: 'already-published', tag: approval.tag };
    }
  }
  check(approval.pending, 'Only a pending release PR may stage a release');
  if (!existingTag) {
    await api.request('/git/refs', { method: 'POST', body: { ref: `refs/tags/${approval.tag}`, sha: approval.sha } });
  }
  if (!release) {
    release = await api.request('/releases', { method: 'POST', body: {
      tag_name: approval.tag, target_commitish: approval.sha, name: `Vishot ${approval.version}`,
      body: `${approval.notes}\n\n${marker}`, draft: true, prerelease: false,
    } });
  }
  // Only draft bytes may be repaired. Upload errors (including 502 starter
  // assets and lost responses) leave a draft for the next explicit rerun.
  const assets = await api.list(`/releases/${release.id}/assets`);
  const retained = new Set();
  for (const asset of assets) {
    const expected = files.get(asset.name);
    const bytes = asset.state === 'uploaded' && expected
      ? await api.request(`/releases/assets/${asset.id}`, { binary: true }) : undefined;
    if (bytes?.equals(expected) && !retained.has(asset.name)) retained.add(asset.name);
    else await api.request(`/releases/assets/${asset.id}`, { method: 'DELETE' });
  }
  for (const [name, bytes] of files) {
    if (!retained.has(name)) {
      const upload = release.upload_url.replace(/\{.*$/, '');
      await api.request(`${upload}?name=${encodeURIComponent(name)}`, { method: 'POST', body: bytes, upload: true });
    }
  }
  validatePackages(await remoteFiles(api, release), approval);
  // Queue order is not guaranteed by Actions concurrency. Recheck immediately
  // before the sole visibility transition, inside the serialized workflow.
  release = await guard(api, approval);
  check(release?.draft, 'Draft changed during staging');
  check(await tagCommit(api, approval.tag) === approval.sha, 'Tag changed during staging');
  await api.request(`/releases/${release.id}`, { method: 'PATCH', body: {
    draft: false, prerelease: false, make_latest: 'true',
  } });
  await finishLabels(api, approval.prNumber);
  return { status: 'published', tag: approval.tag };
}

async function finishLabels(api, number) {
  // Add first so interruption cannot leave the PR without a lifecycle label.
  await api.request(`/issues/${number}/labels`, { method: 'POST', body: { labels: ['autorelease: tagged'] } });
  try {
    await api.request(`/issues/${number}/labels/${encodeURIComponent('autorelease: pending')}`, { method: 'DELETE' });
  } catch (error) { if (error.status !== 404) throw error; }
}
