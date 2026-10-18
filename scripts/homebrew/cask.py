#!/usr/bin/env python3
"""Generate a Vishot cask from a complete release package. Never publishes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


REPOSITORY = "dartyuhov/vishot"
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def generate_cask(packages, release, repository, source_commit, lockfile):
    """Return cask source; inputs are GitHub API objects and downloaded assets."""
    require(isinstance(repository, dict) and isinstance(release, dict),
            "Expected repository and release JSON objects")
    require(repository.get("full_name") == REPOSITORY and
            repository.get("private") is False and repository.get("visibility") == "public",
            "Expected public dartyuhov/vishot repository metadata")
    tag = release.get("tag_name")
    require(isinstance(tag, str) and re.fullmatch("v" + VERSION, tag),
            "Expected a regular v<major>.<minor>.<patch> release tag")
    require(release.get("draft") is False and release.get("prerelease") is False and
            bool(release.get("published_at")), "Expected a published regular release")
    version = tag[1:]
    assets = release.get("assets")
    require(isinstance(assets, list) and all(isinstance(a, dict) for a in assets),
            "Expected release asset metadata")
    names = [a.get("name") for a in assets]
    require(all(isinstance(name, str) for name in names) and len(set(names)) == len(names),
            "Invalid or duplicate release asset names")
    assets = {a["name"]: a for a in assets}
    require(set(assets) == {f"Vishot-{version}-{arch}.dmg{suffix}"
                            for arch in ("arm64", "x86_64")
                            for suffix in ("", ".sha256", ".json")},
            "Incomplete or unexpected release asset set")
    require(isinstance(source_commit, str) and re.fullmatch(r"[0-9a-f]{40}", source_commit),
            "Expected the release tag's resolved full source commit SHA")
    lock_digest = sha256(lockfile)
    digests = {}
    for arch in ("arm64", "x86_64"):
        dmg = Path(packages) / f"Vishot-{version}-{arch}.dmg"
        for suffix in ("", ".sha256", ".json"):
            name = dmg.name + suffix
            asset = assets.get(name, {})
            require(asset.get("state") == "uploaded", f"Missing uploaded asset: {name}")
            require(asset.get("browser_download_url") ==
                    f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}",
                    f"Unexpected release URL: {name}")
            path = Path(packages) / name
            require(path.is_file() and path.stat().st_size > 0 and
                    asset.get("size") == path.stat().st_size, f"Missing or truncated asset: {name}")
            if asset.get("digest") is not None:
                require(asset["digest"] == "sha256:" + sha256(path),
                        f"GitHub asset digest mismatch: {name}")
        digest = sha256(dmg)
        require(dmg.with_suffix(".dmg.sha256").read_text() == f"{digest}  {dmg.name}\n",
                f"DMG checksum mismatch: {dmg.name}")
        manifest = json.loads(dmg.with_suffix(".dmg.json").read_text())
        require(isinstance(manifest, dict), f"Invalid manifest: {dmg.name}")
        for key, expected in {"asset": dmg.name, "sha256": digest, "architecture": arch, "build": version,
                              "version": version, "source_commit": source_commit,
                              "package_resolved_sha256": lock_digest}.items():
            require(manifest.get(key) == expected, f"Manifest {key} mismatch: {dmg.name}")
        for key in ("xcode", "swift"):
            require(isinstance(manifest.get(key), str) and manifest[key].strip(),
                    f"Missing manifest {key}: {dmg.name}")
        digests[arch] = digest
    return '''cask "vishot" do
  arch arm: "arm64", intel: "x86_64"

  version "%s"
  sha256 arm:   "%s",
         intel: "%s"

  url "https://github.com/dartyuhov/vishot/releases/download/v#{version}/Vishot-#{version}-#{arch}.dmg",
      verified: "github.com/dartyuhov/vishot/"
  name "Vishot"
  desc "Keyboard-first screenshot tool"
  homepage "https://vishot.dev/"

  depends_on macos: ">= :sonoma"

  app "Vishot.app"
end
''' % (version, digests["arm64"], digests["x86_64"])


def validate_cask(path, expected):
    """Validate only trusted generated cask source; Homebrew evaluates Ruby."""
    require(Path(path).read_text() == expected, "Cask differs from validated release package")
    env = {**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"}
    result = subprocess.run([
        "brew", "ruby", str(Path(__file__).with_name("inspect-cask.rb")),
        str(Path(path).resolve()),
    ], env=env, capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["generate", "validate"])
    for name in ("packages", "release", "repository", "lockfile"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--cask", type=Path)
    args = parser.parse_args()
    expected = generate_cask(args.packages, json.loads(args.release.read_text()),
                             json.loads(args.repository.read_text()),
                             args.source_commit, args.lockfile)
    if args.command == "generate":
        sys.stdout.write(expected)
    else:
        require(args.cask is not None, "validate requires --cask")
        metadata = validate_cask(args.cask, expected)
        print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Cask validation failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
