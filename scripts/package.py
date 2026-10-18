#!/usr/bin/env python3
"""Native macOS bundle and DMG packaging/validation. No publication privileges."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
POSITIONS = {"Vishot.app": (160, 160), "Applications": (480, 160), "Install.txt": (320, 310)}


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_app(app, args):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key, expected in {
        "CFBundleIdentifier": "com.dartsiukhou.vishot",
        "CFBundleExecutable": "Vishot", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": args.version, "CFBundleVersion": args.build,
        "VishotSourceCommit": args.commit, "LSMinimumSystemVersion": "14.0",
        "CFBundleIconFile": "AppIcon", "LSUIElement": True,
    }.items():
        require(info.get(key) == expected, f"{key}: expected {expected!r}, got {info.get(key)!r}")
    binary = app / "Contents/MacOS/Vishot"
    require(os.access(binary, os.X_OK), "Missing executable permission")
    require(run("lipo", "-archs", str(binary)).decode().strip() == args.arch,
            f"Expected exactly the {args.arch} architecture")
    # Check the Mach-O load command, not just the plist's compatibility claim.
    load = run("otool", "-l", str(binary)).decode()
    require(re.search(r"\bminos 14\.0\b", load), "Executable must target macOS 14.0")
    resources = app / "Contents/Resources"
    for name in ("AppIcon.icns", "ThirdPartyNotices.txt", "FontLicenses.txt"):
        require((resources / name).read_bytes() == (ROOT / "Resources" / name).read_bytes(),
                f"Missing or inconsistent resource: {name}")
    for family in ("silkscreen", "jetbrains-mono"):
        for weight in (400, 700):
            name = f"{family}-latin-{weight}-normal.woff2"
            require((resources / "Fonts" / name).read_bytes() == (ROOT / "site/fonts" / name).read_bytes(),
                    f"Missing or inconsistent font: {name}")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    if args.adhoc:
        signature = run("codesign", "-dv", "--verbose=4", str(app)).decode()
        require("Signature=adhoc" in signature, "CI package must be explicitly ad-hoc signed")


def asset_name(args):
    return f"Vishot-{args.version}-{args.arch}.dmg"


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


@contextmanager
def mounted(dmg):
    with tempfile.TemporaryDirectory(prefix="vishot-mount-") as temp:
        mount = Path(temp) / "volume"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg))
        try:
            yield mount
        finally:
            # A failed detach must fail the gate, rather than leave an unnoticed mounted image.
            run("hdiutil", "detach", str(mount))


def validate_dmg(dmg, args):
    from ds_store import DSStore
    require(dmg.name == asset_name(args), "Incorrect DMG asset name")
    digest = sha256(dmg)
    require(dmg.with_suffix(".dmg.sha256").read_text() == f"{digest}  {dmg.name}\n",
            "DMG checksum mismatch")
    manifest = json.loads(dmg.with_suffix(".dmg.json").read_text())
    for key, expected in {"asset": dmg.name, "sha256": digest, "architecture": args.arch,
                          "version": args.version, "build": args.build,
                          "source_commit": args.commit,
                          "package_resolved_sha256": sha256(ROOT / "Package.resolved")}.items():
        require(manifest.get(key) == expected, f"Manifest {key} mismatch")
    image = plistlib.loads(run("hdiutil", "imageinfo", "-plist", str(dmg)))
    require(image.get("Format") == "UDZO", "Expected a compressed UDZO disk image")
    run("hdiutil", "verify", str(dmg))
    with mounted(dmg) as mount:
        validate_app(mount / "Vishot.app", args)
        require((mount / "Applications").is_symlink() and
                os.readlink(mount / "Applications") == "/Applications", "Invalid Applications shortcut")
        require((mount / "Install.txt").read_bytes() == (ROOT / "Resources/Install.txt").read_bytes(),
                "Missing installation instructions")
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            require(store["."]["vSrn"] == (b"long", 1), "Invalid Finder view settings")
            require(store["."]["icvl"] == (b"type", b"icnv"), "Expected Finder icon view")
            require(store["."]["icvp"]["iconSize"] == 96.0, "Expected readable installer icons")
            require(store["."]["bwsp"]["WindowBounds"] == "{{100, 100}, {640, 420}}",
                    "Invalid installer window layout")
            for name, position in POSITIONS.items():
                require(store[name]["Iloc"] == position, f"Invalid installer icon position: {name}")


def package(output, args):
    from ds_store import DSStore
    require(os.uname().machine == args.arch, "Package on a native architecture host")
    require(run("git", "-C", str(ROOT), "rev-parse", "HEAD").decode().strip() == args.commit,
            "Source commit differs from checkout")
    app = ROOT / "build/Vishot.app"
    validate_app(app, args)
    output.mkdir(parents=True, exist_ok=True)
    dmg = output / asset_name(args)
    require(not any(path.exists() for path in (dmg, dmg.with_suffix(".dmg.sha256"),
                                               dmg.with_suffix(".dmg.json"))),
            "Output already exists; use an empty output directory")
    with tempfile.TemporaryDirectory(prefix="vishot-stage-") as temp:
        stage = Path(temp)
        shutil.copytree(app, stage / "Vishot.app")
        (stage / "Applications").symlink_to("/Applications")
        shutil.copyfile(ROOT / "Resources/Install.txt", stage / "Install.txt")
        # No Finder automation or GUI session is needed on hosted runners.
        with DSStore.open(str(stage / ".DS_Store"), "w+") as store:
            store["."]["vSrn"] = ("long", 1)
            store["."]["icvl"] = ("type", b"icnv")
            store["."]["bwsp"] = {"WindowBounds": "{{100, 100}, {640, 420}}",
                                      "ShowToolbar": False, "ShowSidebar": False,
                                      "ShowStatusBar": False, "ShowTabView": False,
                                      "ContainerShowSidebar": False}
            store["."]["icvp"] = {"viewOptionsVersion": 1, "iconSize": 96.0,
                                      "textSize": 14.0, "arrangeBy": "none",
                                      "gridSpacing": 100.0, "gridOffsetX": 0.0,
                                      "gridOffsetY": 0.0, "labelOnBottom": True,
                                      "showIconPreview": True, "backgroundType": 1,
                                      "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0,
                                      "backgroundColorBlue": 1.0}
            for name, position in POSITIONS.items():
                store[name]["Iloc"] = position
        run("hdiutil", "create", "-format", "UDZO", "-fs", "HFS+", "-volname",
            f"Vishot {args.version}", "-srcfolder", str(stage), str(dmg))
    digest = sha256(dmg)
    dmg.with_suffix(".dmg.sha256").write_text(f"{digest}  {dmg.name}\n")
    manifest = {"asset": dmg.name, "sha256": digest, "architecture": args.arch,
                "version": args.version, "build": args.build, "source_commit": args.commit,
                "package_resolved_sha256": sha256(ROOT / "Package.resolved"),
                "xcode": run("xcodebuild", "-version").decode().strip(),
                "swift": run("swift", "--version").decode().strip()}
    dmg.with_suffix(".dmg.json").write_text(json.dumps(manifest, indent=2) + "\n")
    validate_dmg(dmg, args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate-app", "package", "validate-dmg"])
    parser.add_argument("path", type=Path)
    parser.add_argument("--arch", required=True, choices=["arm64", "x86_64"])
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--adhoc", action="store_true")
    args = parser.parse_args()
    require(re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.version),
            "Expected a regular major.minor.patch version")
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.build), "Expected numeric build version")
    require(re.fullmatch(r"[0-9a-f]{40}", args.commit), "Expected a full source commit SHA")
    {"validate-app": validate_app, "package": package,
     "validate-dmg": validate_dmg}[args.command](args.path.resolve(), args)
    print(f"Validated {args.path}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Package validation failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.output.decode(errors="replace"), file=sys.stderr)
        sys.exit(1)
