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
            "--commit", commit, "--adhoc",
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
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)], check=True,
                       capture_output=True)

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
    def command(cls, command, path):
        return subprocess.run([
            sys.executable, str(ROOT / "scripts/package.py"), command, str(path),
            "--arch", ARCH, "--version", VERSION, "--build", VERSION,
            "--commit", COMMIT, "--adhoc",
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
