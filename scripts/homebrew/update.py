#!/usr/bin/env python3
"""Validate a public release and atomically advance the owned Homebrew tap."""
import argparse
import base64
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.request import Request, urlopen

from cask import REPOSITORY, VERSION, generate_cask, require, validate_cask

TAP = "https://github.com/dartyuhov/homebrew-tap.git"


def git(directory, *args, check=True):
    return subprocess.run(["git", "-C", str(directory), *args], check=check,
                          capture_output=True, text=True)


def cask_version(source):
    matches = re.findall(r'^  version "(' + VERSION + r')"$', source, re.MULTILINE)
    require(len(matches) == 1, "Expected one regular cask version; inspect the tap manually")
    return tuple(map(int, matches[0][0].split(".")))


def update_tap(remote, candidate):
    """Push one fast-forward commit; re-read/recheck after a competing writer wins.

    The caller validates candidate with the release generator/Homebrew first.
    No force push, merge, or rollback is used, including after a lost response.
    """
    version = cask_version(candidate)
    with tempfile.TemporaryDirectory(prefix="vishot-tap-") as temp:
        checkout = Path(temp) / "tap"
        subprocess.run(["git", "clone", "--no-checkout", "--single-branch", "--branch", "main",
                        remote, str(checkout)], check=True, capture_output=True, text=True)
        for attempt in range(4):
            git(checkout, "fetch", "origin", "refs/heads/main")
            base = git(checkout, "rev-parse", "FETCH_HEAD").stdout.strip()
            git(checkout, "checkout", "--detach", "--force", base)
            path = checkout / "Casks" / "vishot.rb"
            require(not path.is_symlink() and not path.parent.is_symlink(),
                    "Cask path must not be a symlink")
            if path.exists():
                previous = path.read_text()
                old = cask_version(previous)
                require(old <= version, "Stale tap update: a newer cask is already published")
                if old == version:
                    require(previous == candidate, "Same-version cask differs; refusing replacement")
                    return "already-current"
            if attempt == 3:
                break
            path.parent.mkdir(exist_ok=True)
            path.write_text(candidate)
            git(checkout, "add", "--", "Casks/vishot.rb")
            git(checkout, "-c", "user.name=Vishot tap updater", "-c",
                "user.email=vishot-tap@users.noreply.github.com", "-c", "commit.gpgsign=false",
                "commit", "-m", "Update vishot to " + ".".join(map(str, version)))
            pushed = git(checkout, "push", "origin", "HEAD:refs/heads/main", check=False)
            if pushed.returncode == 0:
                return "updated"
            # A rejection or lost response is safe to retry only from fresh remote state.
            # The next iteration also detects an already-accepted commit idempotently.
        raise ValueError("Tap push failed after three attempts; no rollback performed. "
                         "Inspect tap main, then rerun the tap update. " + pushed.stderr)


class PublicGitHub:
    """Read-only, unauthenticated public REST/download boundary. No app token."""
    def __init__(self, open_url=urlopen):
        self.open_url = open_url

    def request(self, path):
        request = Request("https://api.github.com/repos/" + REPOSITORY + path,
                          headers={"Accept": "application/vnd.github+json",
                                   "X-GitHub-Api-Version": "2022-11-28",
                                   "User-Agent": "vishot-tap-updater"})
        with self.open_url(request, timeout=60) as response:
            return json.load(response)

    def download(self, url, destination):
        request = Request(url, headers={"User-Agent": "vishot-tap-updater"})
        with self.open_url(request, timeout=120) as response, Path(destination).open("wb") as out:
            while chunk := response.read(1024 * 1024):
                out.write(chunk)


def release_inputs(api, tag):
    repository = api.request("")
    require(repository.get("full_name") == REPOSITORY and repository.get("private") is False
            and repository.get("visibility") == "public", "App repository must be public")
    release = api.request("/releases/tags/" + tag)
    require(release.get("tag_name") == tag and release.get("draft") is False
            and release.get("prerelease") is False and release.get("published_at"),
            "Expected a public regular release")
    require(type(release.get("id")) is int, "Missing release ID")
    assets = []
    for page in range(1, 101):
        rows = api.request(f'/releases/{release["id"]}/assets?per_page=100&page={page}')
        require(isinstance(rows, list), "Expected release assets")
        assets.extend(rows)
        if len(rows) < 100:
            break
    else:
        raise ValueError("Too many release assets")
    release["assets"] = assets
    source = api.request("/commits/" + tag).get("sha")
    require(isinstance(source, str) and re.fullmatch(r"[0-9a-f]{40}", source),
            "Release tag must resolve to a full source commit")
    return repository, release, source


def prepare_candidate(api, tag, directory):
    """Download and validate exact public bytes, including source lockfile provenance."""
    require(re.fullmatch("v" + VERSION, tag), "Expected regular v<major>.<minor>.<patch> tag")
    repository, release, source = release_inputs(api, tag)
    directory = Path(directory)
    lock = api.request("/contents/Package.resolved?ref=" + source)
    require(lock.get("encoding") == "base64", "Expected source lockfile")
    lockfile = directory / "Package.resolved"
    lockfile.write_bytes(base64.b64decode(lock["content"], validate=False))
    required = {f"Vishot-{tag[1:]}-{arch}.dmg{suffix}"
                for arch in ("arm64", "x86_64") for suffix in ("", ".sha256", ".json")}
    names = [asset.get("name") for asset in release["assets"]]
    require(all(isinstance(name, str) for name in names) and len(names) == len(set(names)),
            "Invalid or duplicate release assets")
    require(required <= set(names), "Missing required release assets")
    for asset in release["assets"]:
        name = asset["name"]
        if name not in required:
            continue
        url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}"
        require(asset.get("state") == "uploaded" and asset.get("browser_download_url") == url,
                "Unexpected release asset state or URL: " + name)
        api.download(url, directory / name)
    candidate = generate_cask(directory, release, repository, source, lockfile)
    path = directory / "vishot.rb"
    path.write_text(candidate)
    validate_cask(path, candidate)
    # Refuse a moving tag, withdrawn release, or changed assets while downloading.
    fresh_repository, fresh_release, fresh_source = release_inputs(api, tag)
    require(source == fresh_source and release["id"] == fresh_release["id"],
            "Release identity changed during validation")
    require(generate_cask(directory, fresh_release, fresh_repository, fresh_source, lockfile)
            == candidate, "Release assets changed during validation")
    return candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="vishot-public-release-") as temp:
        candidate = prepare_candidate(PublicGitHub(), args.tag, temp)
        print(update_tap(TAP, candidate))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Tap update failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
