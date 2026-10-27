#!/usr/bin/env python3
"""Exercise the package boundary against a real, signed release app (macOS only)."""
import os
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/Vishot.app"
ARCH = os.uname().machine
VERSION = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
COMMIT = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
# CI explicitly uses ad-hoc signing; local tests retain the development identity.
ADHOC = "Signature=adhoc" in subprocess.check_output(
    ["codesign", "-dv", "--verbose=4", str(APP)], stderr=subprocess.STDOUT, text=True)
SIGN_IDENTITY = "-" if ADHOC else os.environ.get("VISHOT_SIGN_IDENTITY", "Apple Development")


class AppBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vishot-package-test-")
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Vishot.app"
        shutil.copytree(APP, self.app)

    def validate(self, arch=ARCH, version=VERSION, commit=COMMIT):
        return subprocess.run([
            sys.executable, str(ROOT / "scripts/package.py"), "validate-app", str(self.app),
            "--arch", arch, "--version", version, "--build", VERSION,
            "--commit", commit, *(["--adhoc"] if ADHOC else []),
        ], capture_output=True, text=True)

    def test_accepts_real_native_signed_app(self):
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_wrong_architecture_version_build_and_commit(self):
        for values in ({"arch": "x86_64" if ARCH == "arm64" else "arm64"},
                       {"version": "9.9.9"}, {"commit": "0" * 40}):
            with self.subTest(values=values):
                self.assertNotEqual(self.validate(**values).returncode, 0)
        info = self.app / "Contents/Info.plist"
        metadata = plistlib.loads(info.read_bytes())
        metadata["CFBundleVersion"] = "999"
        info.write_bytes(plistlib.dumps(metadata))
        self.resign()
        self.assertNotEqual(self.validate().returncode, 0)

    def resign(self):
        subprocess.run(["codesign", "--force", "--sign", SIGN_IDENTITY, str(self.app)], check=True,
                       capture_output=True)

    def test_rejects_missing_or_nonexecutable_cli_even_when_app_resigned(self):
        helper = self.app / "Contents/Helpers/vishot"
        helper.chmod(0o644)
        self.resign()
        self.assertNotEqual(self.validate().returncode, 0)
        helper.unlink()
        self.resign()
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_resigned_cli_with_wrong_version_or_non_native_program(self):
        helper = self.app / "Contents/Helpers/vishot"
        # Signed executable text is still not the compiled native CLI.
        helper.write_text('#!/bin/sh\nprintf \'{"schemaVersion":1,"ok":true,"version":"9.9.9"}\\n\'\n')
        helper.chmod(0o755)
        subprocess.run(["codesign", "--force", "--sign", SIGN_IDENTITY, str(helper)], check=True,
                       capture_output=True)
        self.resign()
        self.assertNotEqual(self.validate().returncode, 0)

    def test_rejects_native_signed_cli_version_architecture_and_deployment_mismatches(self):
        helper = self.app / "Contents/Helpers/vishot"
        source = Path(self.temp.name) / "substitute.c"
        for arch, minimum, version in [(ARCH, "14.0", "9.9.9"),
                                        ("x86_64" if ARCH == "arm64" else "arm64", "14.0", VERSION),
                                        (ARCH, "15.0", VERSION)]:
            with self.subTest(arch=arch, minimum=minimum, version=version):
                # Compiled boundary substitute, not a mock of lipo/otool/codesign.
                payload = json.dumps({"schemaVersion": 1, "ok": True, "version": version})
                source.write_text('extern int puts(const char *); int main(void) { puts(' +
                                  json.dumps(payload) + '); return 0; }\n')
                helper.unlink()
                subprocess.run(["xcrun", "clang", "-target", f"{arch}-apple-macos{minimum}",
                                str(source), "-o", str(helper)], check=True, capture_output=True)
                subprocess.run(["codesign", "--force", "--sign", SIGN_IDENTITY, str(helper)],
                               check=True, capture_output=True)
                self.resign()
                result = self.validate()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("version" if version != VERSION else "architecture" if arch != ARCH else "14.0",
                              result.stderr)

    def test_rejects_unsigned_nested_cli_even_when_outer_app_resigned(self):
        helper = self.app / "Contents/Helpers/vishot"
        subprocess.run(["codesign", "--remove-signature", str(helper)], check=True)
        # codesign can refuse to seal invalid nested code; either rejection is valid.
        result = subprocess.run(["codesign", "--force", "--sign", SIGN_IDENTITY, str(self.app)], capture_output=True)
        if result.returncode == 0:
            self.assertNotEqual(self.validate().returncode, 0)

    def test_cli_version_tracks_app_metadata_without_service_or_development_path(self):
        info = self.app / "Contents/Info.plist"
        metadata = plistlib.loads(info.read_bytes())
        metadata["CFBundleShortVersionString"] = "9.8.7"
        metadata["CFBundleVersion"] = "9.8.7"
        info.write_bytes(plistlib.dumps(metadata))
        self.resign()
        result = subprocess.run([str(self.app / "Contents/Helpers/vishot"), "--version"],
                                env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"schemaVersion": 1, "ok": True, "version": "9.8.7"})
        self.assertEqual(result.stderr, "")

    def test_rejects_missing_resources_even_when_resigned(self):
        resources = self.app / "Contents/Resources"
        for path in [resources / "AppIcon.icns", resources / "ThirdPartyNotices.txt",
                     resources / "FontLicenses.txt", *sorted((resources / "Fonts").glob("*.woff2"))]:
            with self.subTest(resource=path.name):
                original = path.read_bytes()
                path.unlink()
                self.resign()
                self.assertNotEqual(self.validate().returncode, 0)
                path.write_bytes(original)
        self.resign()
        self.assertEqual(self.validate().returncode, 0)

    def test_rejects_unsigned_and_tampered_executable(self):
        subprocess.run(["codesign", "--remove-signature", str(self.app)], check=True)
        self.assertNotEqual(self.validate().returncode, 0)
        self.resign()
        binary = self.app / "Contents/MacOS/Vishot"
        with binary.open("ab") as f:
            f.write(b"tampered")
        self.assertNotEqual(self.validate().returncode, 0)


class DiskImageBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="vishot-dmg-test-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.output = Path(cls.temp.name)
        cls.dmg = cls.output / f"Vishot-{VERSION}-{ARCH}.dmg"
        result = cls.command("package", cls.output)
        if result.returncode:
            raise AssertionError(result.stderr)

    @classmethod
    def command(cls, command, path, version=VERSION):
        return subprocess.run([
            sys.executable, str(ROOT / "scripts/package.py"), command, str(path),
            "--arch", ARCH, "--version", version, "--build", version,
            "--commit", COMMIT, *(["--adhoc"] if ADHOC else []),
        ], capture_output=True, text=True)

    def test_accepts_compressed_mounted_installer_and_exact_checksums(self):
        result = self.command("validate-dmg", self.dmg)
        self.assertEqual(result.returncode, 0, result.stderr)
        digest = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        self.assertEqual(self.dmg.with_suffix(".dmg.sha256").read_text(),
                         f"{digest}  {self.dmg.name}\n")
        manifest = json.loads(self.dmg.with_suffix(".dmg.json").read_text())
        self.assertEqual(manifest["source_commit"], COMMIT)
        self.assertEqual(manifest["sha256"], digest)
        self.assertEqual(manifest["architecture"], ARCH)
        self.assertEqual(manifest["version"], VERSION)
        self.assertEqual(manifest["build"], VERSION)

    def test_dmg_and_homebrew_app_installations_preserve_cli_and_upgrade_link(self):
        for delivery in ("dmg-copy", "homebrew-artifact"):
            with self.subTest(delivery=delivery), tempfile.TemporaryDirectory(prefix="vishot installed apps ") as temp:
                root = Path(temp)
                appdir = root / "Custom Applications"
                appdir.mkdir()
                installed = appdir / "Vishot.app"
                homebin = root / "User Home/.local/bin"
                homebin.mkdir(parents=True)
                link = homebin / "vishot"
                link_inode = None
                for revision in ("original", "replacement"):
                    expected_version = VERSION if revision == "original" else "9.8.7"
                    mount = root / "mount"
                    mount.mkdir(exist_ok=True)
                    subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint",
                                    str(mount), str(self.dmg)], check=True, capture_output=True)
                    try:
                        if installed.exists():
                            shutil.rmtree(installed)
                        if delivery == "dmg-copy":
                            shutil.copytree(mount / "Vishot.app", installed)
                        else:
                            # No release download/install or user Caskroom writes: run
                            # the same app artifact against a locally mounted real DMG.
                            stage = root / revision / VERSION
                            stage.mkdir(parents=True)
                            shutil.copytree(mount / "Vishot.app", stage / "Vishot.app")
                            cask = root / "vishot.rb"
                            cask.write_text('cask "vishot" do\n  version "' + VERSION +
                                            '"\n  sha256 "' + hashlib.sha256(self.dmg.read_bytes()).hexdigest() +
                                            '"\n  url "file://' + str(self.dmg) +
                                            '"\n  app "Vishot.app"\nend\n')
                            brew = subprocess.run(["brew", "ruby", str(ROOT / "scripts/homebrew/install-app-fixture.rb"),
                                            str(cask), str(stage), str(appdir)],
                                           capture_output=True, text=True,
                                           env={**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"})
                            self.assertEqual(brew.returncode, 0, brew.stdout + brew.stderr)
                    finally:
                        subprocess.run(["hdiutil", "detach", str(mount)], check=True, capture_output=True)
                    if revision == "replacement":
                        # Controlled next-version fixture, not a distributable release.
                        info = installed / "Contents/Info.plist"
                        metadata = plistlib.loads(info.read_bytes())
                        metadata.update(CFBundleShortVersionString=expected_version, CFBundleVersion=expected_version)
                        info.write_bytes(plistlib.dumps(metadata))
                        subprocess.run(["codesign", "--force", "--sign", SIGN_IDENTITY, str(installed)],
                                       check=True, capture_output=True)
                    if not link.is_symlink():
                        link.symlink_to(installed / "Contents/Helpers/vishot")
                    if link_inode is None:
                        link_inode = link.lstat().st_ino
                    result = subprocess.run([str(link), "--version"], env={"PATH": "/usr/bin:/bin"},
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), {"schemaVersion": 1, "ok": True, "version": expected_version})
                    self.assertEqual(result.stderr, "")
                    self.assertEqual(link.lstat().st_ino, link_inode)
                    result = self.command("validate-app", installed, version=expected_version)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_incomplete_installer_contents_and_layout(self):
        from ds_store import DSStore
        for damage in ("app", "shortcut", "instructions", "missing-layout", "layout"):
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as temp:
                stage = Path(temp) / "stage"
                mount = Path(temp) / "mount"
                mount.mkdir()
                subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint",
                                str(mount), str(self.dmg)], check=True, capture_output=True)
                try:
                    shutil.copytree(mount, stage, symlinks=True)
                finally:
                    subprocess.run(["hdiutil", "detach", str(mount)], check=True, capture_output=True)
                if damage == "app":
                    shutil.rmtree(stage / "Vishot.app")
                elif damage == "shortcut":
                    (stage / "Applications").unlink()
                    (stage / "Applications").symlink_to("/tmp")
                elif damage == "instructions":
                    (stage / "Install.txt").unlink()
                elif damage == "missing-layout":
                    (stage / ".DS_Store").unlink()
                else:
                    with DSStore.open(str(stage / ".DS_Store"), "r+") as store:
                        store["Applications"]["Iloc"] = (160, 160)
                dmg = Path(temp) / self.dmg.name
                subprocess.run(["hdiutil", "create", "-quiet", "-format", "UDZO", "-srcfolder",
                                str(stage), str(dmg)], check=True)
                # Refresh checksums too: reject the actual contents, not a stale checksum.
                shutil.copyfile(self.dmg.with_suffix(".dmg.json"), dmg.with_suffix(".dmg.json"))
                digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
                manifest = json.loads(dmg.with_suffix(".dmg.json").read_text())
                manifest["sha256"] = digest
                dmg.with_suffix(".dmg.json").write_text(json.dumps(manifest))
                dmg.with_suffix(".dmg.sha256").write_text(f"{digest}  {dmg.name}\n")
                self.assertNotEqual(self.command("validate-dmg", dmg).returncode, 0)

    def test_rejects_changed_bytes_and_source_identity(self):
        with tempfile.TemporaryDirectory() as temp:
            dmg = Path(temp) / self.dmg.name
            for suffix in (".dmg", ".dmg.sha256", ".dmg.json"):
                shutil.copyfile(self.dmg.with_suffix(suffix), dmg.with_suffix(suffix))
            manifest_path = dmg.with_suffix(".dmg.json")
            manifest = json.loads(manifest_path.read_text())
            manifest["source_commit"] = "0" * 40
            manifest_path.write_text(json.dumps(manifest))
            self.assertNotEqual(self.command("validate-dmg", dmg).returncode, 0)
            shutil.copyfile(self.dmg.with_suffix(".dmg.json"), manifest_path)
            with dmg.open("ab") as f:
                f.write(b"changed bytes")
            self.assertNotEqual(self.command("validate-dmg", dmg).returncode, 0)


if __name__ == "__main__":
    unittest.main()
