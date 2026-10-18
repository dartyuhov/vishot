'use strict';

const { createHash } = require('node:crypto');
const architectures = ['arm64', 'x86_64'];
const regular = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const check = (condition, message) => { if (!condition) throw new Error(message); };
const names = version => architectures.flatMap(arch => {
  const name = `Vishot-${version}-${arch}.dmg`;
  return [name, `${name}.sha256`, `${name}.json`];
});

// Both publication and the public site use this manifest contract. Publication
// hashes actual DMG bytes; the site uses GitHub's SHA-256 asset digest so a page
// request never downloads installers. Missing digest metadata fails closed.
function validateManifest(manifest, { asset, architecture, version, digest, source, lockHash }) {
  check(manifest && typeof manifest === 'object' && !Array.isArray(manifest), 'Invalid manifest');
  for (const [key, value] of Object.entries({ asset, architecture, version, build: version,
    sha256: digest, source_commit: source, package_resolved_sha256: lockHash })) {
    check(manifest[key] === value, `Manifest ${key} mismatch: ${asset}`);
  }
  for (const key of ['xcode', 'swift']) check(typeof manifest[key] === 'string' && manifest[key].trim(), `Missing ${key}`);
}

module.exports = { architectures, regular, hash, check, names, validateManifest };
