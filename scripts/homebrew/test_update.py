"""Updater boundary checks use controlled release bytes and real local Git remotes."""
import importlib.util
import base64
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.error import HTTPError

import test_cask

HERE = Path(__file__).resolve().parent


def git(directory, *args):
    return subprocess.run(["git", "-C", str(directory), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


class TapUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vishot-tap-update-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / "tap.git"
        self.seed = self.root / "seed"
        subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(self.remote)],
                       check=True, capture_output=True)
        subprocess.run(["git", "clone", str(self.remote), str(self.seed)],
                       check=True, capture_output=True)
        (self.seed / "README.md").write_text("Owned tap fixture\n")
        self.commit("Initialize tap")
        git(self.seed, "push", "origin", "main")

    def commit(self, message):
        git(self.seed, "add", ".")
        git(self.seed, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "-m", message)

    def updater(self):
        spec = importlib.util.spec_from_file_location("tap_update", HERE / "update.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_update_commits_only_cask_and_retry_is_idempotent(self):
        updater = self.updater()
        candidate = 'cask "vishot" do\n  version "1.2.3"\nend\n'
        before = git(self.remote, "rev-parse", "main")
        self.assertEqual(updater.update_tap(str(self.remote), candidate), "updated")
        after = git(self.remote, "rev-parse", "main")
        self.assertNotEqual(after, before)
        self.assertEqual(git(self.remote, "diff-tree", "--no-commit-id", "--name-only", "-r", after),
                         "Casks/vishot.rb")
        self.assertEqual(git(self.remote, "show", "main:Casks/vishot.rb") + "\n", candidate)
        self.assertEqual(updater.update_tap(str(self.remote), candidate), "already-current")
        self.assertEqual(git(self.remote, "rev-parse", "main"), after)

    def test_stale_or_conflicting_same_version_never_changes_remote(self):
        updater = self.updater()
        current = 'cask "vishot" do\n  version "2.0.0"\nend\n'
        updater.update_tap(str(self.remote), current)
        before = git(self.remote, "rev-parse", "main")
        for candidate, message in [(current.replace("2.0.0", "1.9.9"), "Stale"),
                                   (current + "# changed\n", "Same-version")]:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                updater.update_tap(str(self.remote), candidate)
            self.assertEqual(git(self.remote, "rev-parse", "main"), before)

    def hook(self, source):
        path = self.remote / "hooks" / "pre-receive"
        path.write_text("#!/bin/sh\n" + source)
        path.chmod(0o755)
        return path

    def test_rejected_push_preserves_previous_and_retry_succeeds(self):
        updater = self.updater()
        old = 'cask "vishot" do\n  version "1.2.2"\nend\n'
        updater.update_tap(str(self.remote), old)
        before = git(self.remote, "rev-parse", "main")
        hook = self.hook("exit 1\n")
        candidate = old.replace("1.2.2", "1.2.3")
        with self.assertRaisesRegex(ValueError, "Tap push failed"):
            updater.update_tap(str(self.remote), candidate)
        self.assertEqual(git(self.remote, "rev-parse", "main"), before)
        hook.unlink()
        self.assertEqual(updater.update_tap(str(self.remote), candidate), "updated")
        self.assertEqual(updater.update_tap(str(self.remote), candidate), "already-current")

    def test_competing_newer_update_cannot_be_rolled_back(self):
        entered = self.root / "entered"
        resume = self.root / "resume"
        self.hook(f'if test ! -f "{entered}"; then\n'
                  f'  touch "{entered}"\n'
                  f'  while test ! -f "{resume}"; do sleep 0.05; done\nfi\n')
        driver = ("import sys; sys.path.insert(0, sys.argv[1]); from update import update_tap; "
                  "print(update_tap(sys.argv[2], sys.argv[3]))")
        import sys
        import time
        old = 'cask "vishot" do\n  version "1.2.3"\nend\n'
        process = subprocess.Popen([sys.executable, "-B", "-c", driver, str(HERE),
                                    str(self.remote), old], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not entered.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(entered.exists(), "old writer didn't reach Git receive")
            self.updater().update_tap(str(self.remote), old.replace("1.2.3", "1.2.4"))
        finally:
            resume.touch()
        stdout, stderr = process.communicate(timeout=15)
        self.assertNotEqual(process.returncode, 0, stdout)
        self.assertIn("Stale", stderr)
        self.assertIn('version "1.2.4"', git(self.remote, "show", "main:Casks/vishot.rb"))

    def test_unparseable_previous_cask_fails_closed(self):
        (self.seed / "Casks").mkdir()
        (self.seed / "Casks" / "vishot.rb").write_text('version :latest\n')
        self.commit("Unknown cask")
        git(self.seed, "push", "origin", "main")
        before = git(self.remote, "rev-parse", "main")
        with self.assertRaisesRegex(ValueError, "regular cask version"):
            self.updater().update_tap(str(self.remote), '  version "1.2.3"\n')
        self.assertEqual(git(self.remote, "rev-parse", "main"), before)

    def test_concurrent_unrelated_commit_is_preserved_on_successful_retry(self):
        import sys
        import time
        entered = self.root / "entered"
        resume = self.root / "resume"
        self.hook(f'if test ! -f "{entered}"; then\n'
                  f'  touch "{entered}"\n'
                  f'  while test ! -f "{resume}"; do sleep 0.05; done\nfi\n')
        candidate = 'cask "vishot" do\n  version "1.2.3"\nend\n'
        driver = ("import sys; sys.path.insert(0, sys.argv[1]); from update import update_tap; "
                  "print(update_tap(sys.argv[2], sys.argv[3]))")
        process = subprocess.Popen([sys.executable, "-B", "-c", driver, str(HERE),
                                    str(self.remote), candidate], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not entered.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(entered.exists())
            (self.seed / "README.md").write_text("Concurrent documentation update\n")
            self.commit("Document tap")
            git(self.seed, "push", "origin", "main")
        finally:
            resume.touch()
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertIn("updated", stdout)
        self.assertEqual(git(self.remote, "show", "main:README.md"), "Concurrent documentation update")
        self.assertEqual(git(self.remote, "show", "main:Casks/vishot.rb") + "\n", candidate)

    def test_lost_push_response_reconciles_even_on_last_attempt(self):
        # A process-boundary wrapper executes the real push, then hides its
        # successful result. This models a disconnected client, not failed Git.
        import shutil
        from unittest.mock import patch
        real_git = shutil.which("git")
        commands = self.root / "commands"
        commands.mkdir()
        count = self.root / "push-count"
        wrapper = commands / "git"
        wrapper.write_text('#!/bin/sh\n'
                           'case " $* " in\n'
                           '  *" push "*)\n'
                           f'    n=0; test ! -f "{count}" || n=$(cat "{count}")\n'
                           f'    n=$((n + 1)); printf "%s" "$n" > "{count}"\n'
                           '    if test "$n" -lt 3; then exit 1; fi\n'
                           f'    "{real_git}" "$@" || exit $?\n'
                           '    exit 1;;\n'
                           'esac\n'
                           f'exec "{real_git}" "$@"\n')
        wrapper.chmod(0o755)
        with patch.dict(os.environ, {"PATH": str(commands) + os.pathsep + os.environ["PATH"]}):
            self.assertEqual(self.updater().update_tap(
                str(self.remote), 'cask "vishot" do\n  version "1.2.3"\nend\n'),
                "already-current")
        self.assertEqual(count.read_text(), "3")


class PublicReleaseTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_cask.CaskTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.temp = tempfile.TemporaryDirectory(prefix="vishot-release-download-")
        self.addCleanup(self.temp.cleanup)
        self.calls = []
        self.fixture.release["id"] = 42
        self.release = copy.deepcopy(self.fixture.release)
        self.assets = copy.deepcopy(self.release.pop("assets"))
        self.repository = self.fixture.repository.copy()
        self.commit = self.fixture.commit
        self.fail_download = False
        self.mutate_after_download = None
        self.module = TapUpdateTests.updater(self)
        self.api = self.module.PublicGitHub(self.open_url)

    def open_url(self, request, timeout):
        url = request.full_url
        self.calls.append(url)
        self.assertEqual(request.get_method(), "GET", "tap recovery must never mutate app releases")
        self.assertNotIn("Authorization", request.headers, "public evidence must not use tap credentials")
        api = "https://api.github.com/repos/dartyuhov/vishot"
        if url == api:
            result = self.repository
        elif url == api + "/releases/tags/v1.2.3":
            result = self.release
        elif url == api + "/releases/42/assets?per_page=100&page=1":
            result = self.assets
        elif url == api + "/releases/42/assets?per_page=100&page=2":
            result = []
        elif url == api + "/commits/v1.2.3":
            result = {"sha": self.commit}
        elif url == api + "/contents/Package.resolved?ref=" + self.fixture.commit:
            result = {"encoding": "base64", "content": base64.b64encode(
                self.fixture.lockfile.read_bytes()).decode()}
        elif url.startswith("https://github.com/dartyuhov/vishot/releases/download/v1.2.3/"):
            if self.fail_download:
                raise HTTPError(url, 503, "Controlled unavailable asset", {}, None)
            content = (self.fixture.packages / url.rsplit("/", 1)[1]).read_bytes()
            if self.mutate_after_download:
                self.mutate_after_download()
            return io.BytesIO(content)
        else:
            self.fail("Unexpected production request: " + url)
        return io.BytesIO(json.dumps(result).encode())

    def prepare(self):
        return self.module.prepare_candidate(self.api, "v1.2.3", self.temp.name)

    def test_private_draft_prerelease_or_unpublished_release_never_downloads(self):
        for target, field, value in [(self.repository, "private", True),
                                     (self.release, "draft", True),
                                     (self.release, "prerelease", True),
                                     (self.release, "published_at", None)]:
            with self.subTest(field=field):
                old = target[field]
                target[field] = value
                self.calls.clear()
                with self.assertRaisesRegex(ValueError, "public"):
                    self.prepare()
                self.assertFalse(any("/releases/download/" in url for url in self.calls))
                target[field] = old

    def test_each_missing_asset_or_wrong_url_fails_before_git_or_homebrew(self):
        original = copy.deepcopy(self.assets)
        for index in range(6):
            with self.subTest(missing=original[index]["name"]):
                self.assets = original[:index] + original[index + 1:]
                with self.assertRaisesRegex(ValueError, "Missing required"):
                    self.prepare()
        self.assets = copy.deepcopy(original)
        self.assets[0]["browser_download_url"] = "https://attacker.invalid/asset"
        with self.assertRaisesRegex(ValueError, "URL"):
            self.prepare()
        self.assertFalse(any("attacker" in url for url in self.calls))

    def test_downloaded_checksum_mismatch_is_rejected(self):
        path = self.fixture.packages / "Vishot-1.2.3-x86_64.dmg"
        data = path.read_bytes()
        path.write_bytes(b"!" + data[1:])
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.prepare()

    @unittest.skipUnless(os.environ.get("VISHOT_TEST_HOMEBREW") == "1", "Requires real Homebrew")
    def test_public_download_to_git_retry_uses_real_generator_and_homebrew_no_republication(self):
        tap = TapUpdateTests()
        tap.setUp()
        self.addCleanup(tap.doCleanups)
        before = git(tap.remote, "rev-parse", "main")
        self.fail_download = True
        with self.assertRaises(HTTPError) as failure:
            self.prepare()
        failure.exception.close()
        self.assertEqual(git(tap.remote, "rev-parse", "main"), before)
        self.fail_download = False
        candidate = self.prepare()
        hook = tap.hook("exit 1\n")
        with self.assertRaisesRegex(ValueError, "Tap push failed"):
            self.module.update_tap(str(tap.remote), candidate)
        self.assertEqual(git(tap.remote, "rev-parse", "main"), before)
        hook.unlink()
        self.assertEqual(self.module.update_tap(str(tap.remote), self.prepare()), "updated")
        self.assertEqual(self.module.update_tap(str(tap.remote), self.prepare()), "already-current")
        actual = git(tap.remote, "show", "main:Casks/vishot.rb")
        for digest in self.fixture.digests.values():
            self.assertIn(digest, actual)
        self.assertIn('version "1.2.3"', actual)

    @unittest.skipUnless(os.environ.get("VISHOT_TEST_HOMEBREW") == "1", "Requires real Homebrew")
    def test_paginated_assets_and_moving_source_revalidation(self):
        # The release object's embedded assets are deliberately absent. Required
        # files occur after 100 unrelated assets on the dedicated listing API.
        # Read all pages, then reject the unexpected assets in the six-file contract.
        required = self.assets
        self.assets = [{"name": f"extra-{i}"} for i in range(100)]
        original_open = self.open_url
        pages = []
        def paginated(request, timeout):
            pages.append(request.full_url)
            if request.full_url.endswith("/assets?per_page=100&page=2"):
                return io.BytesIO(json.dumps(required).encode())
            return original_open(request, timeout)
        self.api = self.module.PublicGitHub(paginated)
        with self.assertRaisesRegex(ValueError, "unexpected release asset set"):
            self.prepare()
        self.assertTrue(any(url.endswith("/assets?per_page=100&page=2") for url in pages))
        self.assets = required
        self.api = self.module.PublicGitHub(original_open)
        self.assertIn('version "1.2.3"', self.prepare())
        self.mutate_after_download = lambda: setattr(self, "commit", "b" * 40)
        with self.assertRaisesRegex(ValueError, "identity changed"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
