"""Controlled release fixtures: these bytes are NOT installers or published assets."""
import hashlib
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from cask import generate_cask


class CaskTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vishot-cask-test-")
        self.addCleanup(self.temp.cleanup)
        self.packages = Path(self.temp.name)
        self.commit = "a" * 40
        self.lockfile = self.packages / "Package.resolved"
        self.lockfile.write_bytes(b"controlled lockfile fixture\n")
        self.repository = {"full_name": "dartyuhov/vishot", "private": False,
                           "visibility": "public"}
        self.release = {"tag_name": "v1.2.3", "draft": False, "prerelease": False,
                        "published_at": "2026-10-18T12:00:00Z", "assets": []}
        self.digests = {}
        for arch in ("arm64", "x86_64"):
            name = f"Vishot-1.2.3-{arch}.dmg"
            dmg = self.packages / name
            dmg.write_bytes(f"controlled {arch} fixture, not a DMG\n".encode())
            digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
            self.digests[arch] = digest
            (self.packages / f"{name}.sha256").write_text(f"{digest}  {name}\n")
            manifest = {"asset": name, "sha256": digest, "architecture": arch,
                        "version": "1.2.3", "build": "1.2.3", "source_commit": self.commit,
                        "package_resolved_sha256": hashlib.sha256(self.lockfile.read_bytes()).hexdigest(),
                        "xcode": "Xcode 16.4\nBuild version 16F6", "swift": "Apple Swift version 6.1.2"}
            (self.packages / f"{name}.json").write_text(json.dumps(manifest))
            for suffix in ("", ".sha256", ".json"):
                asset = name + suffix
                self.release["assets"].append({
                    "name": asset, "state": "uploaded",
                    "size": (self.packages / asset).stat().st_size,
                    "browser_download_url": f"https://github.com/dartyuhov/vishot/releases/download/v1.2.3/{asset}",
                })

    def generate(self):
        return generate_cask(self.packages, self.release, self.repository,
                             self.commit, self.lockfile)

    def test_complete_release_generates_versioned_dual_arch_cask(self):
        cask = self.generate()
        self.assertIn('cask "vishot" do', cask)
        self.assertIn('arch arm: "arm64", intel: "x86_64"', cask)
        self.assertIn('version "1.2.3"', cask)
        for digest in self.digests.values():
            self.assertIn(digest, cask)
        self.assertIn('releases/download/v#{version}/Vishot-#{version}-#{arch}.dmg', cask)
        self.assertIn('depends_on macos: ">= :sonoma"', cask)
        self.assertIn('app "Vishot.app"', cask)
        for bypass in ("quarantine", "xattr", "spctl", "installer", "preflight", "postflight", "auto_updates", ":latest", ":no_check"):
            self.assertNotIn(bypass, cask)

    def test_only_complete_public_regular_releases_from_owned_repository(self):
        original_release = copy.deepcopy(self.release)
        original_repository = self.repository.copy()
        cases = [
            ("repository", "private", True),
            ("repository", "private", None),
            ("repository", "visibility", "private"),
            ("repository", "full_name", "someone/vishot"),
            ("release", "draft", True),
            ("release", "prerelease", True),
            ("release", "published_at", None),
            ("release", "tag_name", "v1.2.3-rc.1"),
            ("release", "tag_name", "1.2.3"),
            ("release", "tag_name", "v01.2.3"),
            ("release", "tag_name", 'v1.2.3\"; system(\"false\")'),
            ("release", "assets", original_release["assets"][:-1]),
            ("release", "assets", original_release["assets"] + [original_release["assets"][0]]),
        ]
        for target, key, value in cases:
            with self.subTest(target=target, key=key, value=value):
                self.release = copy.deepcopy(original_release)
                self.repository = original_repository.copy()
                getattr(self, target)[key] = value
                with self.assertRaises(ValueError):
                    self.generate()

        self.release = original_release
        self.repository = original_repository
        for key, value in [("state", "new"), ("size", 0),
                           ("browser_download_url", "https://example.com/wrong.dmg")]:
            with self.subTest(asset_key=key):
                self.release = copy.deepcopy(original_release)
                self.release["assets"][0][key] = value
                with self.assertRaises(ValueError):
                    self.generate()

    def test_package_bytes_sidecars_and_release_identity_must_agree(self):
        originals = {p: p.read_bytes() for p in self.packages.iterdir()}
        original_release = copy.deepcopy(self.release)
        def restore():
            self.release = copy.deepcopy(original_release)
            for path, data in originals.items():
                path.write_bytes(data)

        for arch in ("arm64", "x86_64"):
            dmg = self.packages / f"Vishot-1.2.3-{arch}.dmg"
            checksum = dmg.with_suffix(".dmg.sha256")
            manifest = dmg.with_suffix(".dmg.json")
            for path in (dmg, checksum, manifest):
                with self.subTest(arch=arch, missing=path.name):
                    restore()
                    path.unlink()
                    with self.assertRaises(ValueError):
                        self.generate()
            for path in (dmg, checksum):
                with self.subTest(arch=arch, corrupt=path.name):
                    restore()
                    data = path.read_bytes()
                    path.write_bytes(b"!" + data[1:])  # Same size, different bytes.
                    with self.assertRaises(ValueError):
                        self.generate()
            for key, value in [("asset", "wrong.dmg"), ("sha256", "0" * 64),
                               ("architecture", "universal"), ("version", "1.2.4"),
                               ("build", "2"), ("build", "invalid"),
                               ("source_commit", "b" * 40),
                               ("package_resolved_sha256", "c" * 64),
                               ("xcode", ""), ("swift", None)]:
                with self.subTest(arch=arch, field=key, value=value):
                    restore()
                    data = json.loads(manifest.read_text())
                    data[key] = value
                    manifest.write_text(json.dumps(data))
                    for asset in self.release["assets"]:
                        if asset["name"] == manifest.name:
                            asset["size"] = manifest.stat().st_size
                    with self.assertRaises(ValueError):
                        self.generate()
        restore()
        self.lockfile.write_bytes(b"different checkout lockfile")
        with self.assertRaises(ValueError):
            self.generate()

    def cli(self, *args):
        release = self.packages / "release.json"
        repository = self.packages / "repository.json"
        release.write_text(json.dumps(self.release))
        repository.write_text(json.dumps(self.repository))
        return subprocess.run([
            sys.executable, str(HERE / "cask.py"), *args,
            "--packages", str(self.packages), "--release", str(release),
            "--repository", str(repository), "--source-commit", self.commit,
            "--lockfile", str(self.lockfile),
        ], capture_output=True, text=True)

    def test_generator_cli_emits_nothing_for_invalid_inputs(self):
        result = self.cli("generate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, self.generate())
        self.release["draft"] = True
        result = self.cli("generate")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("published regular release", result.stderr)

    def test_new_release_changes_version_urls_and_checksums_without_latest_alias(self):
        previous = self.generate()
        self.release["tag_name"] = "v1.2.4"
        for asset in self.release["assets"]:
            old = self.packages / asset["name"]
            asset["name"] = asset["name"].replace("1.2.3", "1.2.4")
            asset["browser_download_url"] = asset["browser_download_url"].replace("1.2.3", "1.2.4")
            old.rename(self.packages / asset["name"])
        for arch in ("arm64", "x86_64"):
            dmg = self.packages / f"Vishot-1.2.4-{arch}.dmg"
            dmg.write_bytes(f"next controlled {arch} fixture\n".encode())
            digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
            dmg.with_suffix(".dmg.sha256").write_text(f"{digest}  {dmg.name}\n")
            path = dmg.with_suffix(".dmg.json")
            manifest = json.loads(path.read_text())
            manifest.update(asset=dmg.name, version="1.2.4", build="1.2.4", sha256=digest)
            path.write_text(json.dumps(manifest))
        for asset in self.release["assets"]:
            asset["size"] = (self.packages / asset["name"]).stat().st_size
        current = self.generate()
        self.assertIn('version "1.2.4"', current)
        self.assertNotEqual(previous, current)
        for digest in self.digests.values():
            self.assertNotIn(digest, current)

    def test_incomplete_manifests_and_github_digests_fail_closed(self):
        path = self.packages / "Vishot-1.2.3-arm64.dmg.json"
        manifest = json.loads(path.read_text())
        for field in manifest:
            with self.subTest(missing_field=field):
                incomplete = manifest.copy()
                del incomplete[field]
                path.write_text(json.dumps(incomplete))
                self.release["assets"][2]["size"] = path.stat().st_size
                result = self.cli("generate")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        for invalid in ("{", "[]", "null"):
            with self.subTest(invalid_json=invalid):
                path.write_text(invalid)
                self.release["assets"][2]["size"] = path.stat().st_size
                result = self.cli("generate")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        path.write_text(json.dumps(manifest))
        self.release["assets"][2]["size"] = path.stat().st_size
        for asset in self.release["assets"]:
            asset["digest"] = "sha256:" + hashlib.sha256(
                (self.packages / asset["name"]).read_bytes()).hexdigest()
        self.assertTrue(self.generate())
        for index in range(6):
            with self.subTest(github_digest=index):
                old = self.release["assets"][index]["digest"]
                self.release["assets"][index]["digest"] = "sha256:" + "0" * 64
                with self.assertRaises(ValueError):
                    self.generate()
                self.release["assets"][index]["digest"] = old

    @unittest.skipUnless(os.environ.get("VISHOT_TEST_HOMEBREW") == "1",
                         "Set VISHOT_TEST_HOMEBREW=1 to require real Homebrew DSL validation")
    def test_real_homebrew_loads_both_architectures_and_rejects_changed_cask(self):
        cask = self.packages / "vishot.rb"
        cask.write_text(self.generate())
        result = self.cli("validate", "--cask", str(cask))
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads(result.stdout)
        for arch, brew_arch in (("arm64", "arm"), ("x86_64", "intel")):
            with self.subTest(arch=arch):
                actual = metadata[brew_arch]
                self.assertEqual(actual["version"], "1.2.3")
                self.assertEqual(actual["url"],
                                 f"https://github.com/dartyuhov/vishot/releases/download/v1.2.3/Vishot-1.2.3-{arch}.dmg")
                self.assertEqual(actual["sha256"], self.digests[arch])
                self.assertEqual(actual["depends_on"]["macos"], {">=": ["14"]})
                self.assertEqual(actual["artifacts"], [{"app": ["Vishot.app"],
                                                       "target": "/Applications/Vishot.app"}])
        for before, after in [('>= :sonoma', '>= :ventura'),
                              ('intel: "x86_64"', 'intel: "arm64"'),
                              (self.digests["arm64"], "0" * 64),
                              ('app "Vishot.app"', 'app "Wrong.app"')]:
            with self.subTest(change=after):
                cask.write_text(self.generate().replace(before, after))
                result = self.cli("validate", "--cask", str(cask))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
