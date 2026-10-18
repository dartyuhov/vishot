# Native installer packaging

Vishot ships separate Apple Silicon and Intel installers. The reusable
[`package.yml`](../.github/workflows/package.yml) workflow builds and tests
both architectures from one full source commit SHA. It uploads validated
artifacts without publishing a release.

## Asset contract

Consumers can rely on these case-sensitive filenames for a regular version
such as `0.1.0`:

- Apple Silicon: `Vishot-0.1.0-arm64.dmg`.
- Intel: `Vishot-0.1.0-x86_64.dmg`.
- Each DMG has a `<filename>.sha256` checksum and `<filename>.json` manifest.
- Workflow artifact names are `vishot-package-arm64` and
  `vishot-package-x86_64`.

The general pattern is `Vishot-<version>-<arch>.dmg`, where `<arch>` is
`arm64` or `x86_64`. The version comes from
`Resources/Info.plist:CFBundleShortVersionString`; the generated bundle's
`CFBundleVersion` matches it by default. The source plist's build value is
not a second release-version authority. Local builds can override the build
number with `VISHOT_BUILD_VERSION`.

The checksum uses SHA-256 over the exact compressed DMG bytes. Each manifest
records the asset name, checksum, architecture, version, build, full
`source_commit`, `Package.resolved` checksum, Xcode, and Swift versions. The
signed app also records `VishotSourceCommit` in its plist. A publication
caller must require both artifacts, matching source/version/build/lockfile
identity, and matching checksums before exposing a release. Manifests provide
traceability; they aren't cryptographic source attestations.

The [Homebrew generator](homebrew.md) consumes this complete two-architecture
package contract, checks downloaded bytes and sidecars, and emits a versioned
cask. It doesn't rebuild installers or establish public release availability.

## Reusable workflow

Call the workflow with one full commit SHA and the expected release version:

```yaml
jobs:
  installers:
    uses: ./.github/workflows/package.yml
    with:
      source_sha: ${{ needs.release.outputs.sha }}
      version: ${{ needs.release.outputs.version }}
```

The workflow accepts no secrets and requests only `contents: read`. It uses
native `macos-15` ARM and `macos-15-intel` runners, Xcode 16.4 / Swift 6.1.2,
and a macOS 14.0 target triple for tests and release builds. SwiftPM uses
`--force-resolved-versions`; Python packaging tools are pinned with wheel
hashes in `scripts/packaging-requirements.txt`. Ordinary PRs run the same
package gates through `package-check.yml`.

## Local verification

Run these commands on a native Mac with Xcode and Python 3.11 or newer.
Use your stable development identity for normal local builds:

```sh
swift test --force-resolved-versions
./scripts/build.sh
```

`VISHOT_SIGN_IDENTITY` defaults to `Apple Development`. Set it to a stable
certificate name to override it. CI explicitly sets it to `-` for ad-hoc
signing. The scripts never infer ad-hoc signing from a missing certificate
or a CI environment variable. `./scripts/build.sh install` retains the
existing local install and relaunch behavior.

To reproduce CI packaging explicitly, use an ad-hoc build and a virtual
environment for the build-time tools:

```sh
python3 -m venv build/packaging-venv
build/packaging-venv/bin/python -m pip install --require-hashes \
  --only-binary=:all: -r scripts/packaging-requirements.txt
VISHOT_SIGN_IDENTITY=- ./scripts/build.sh
build/packaging-venv/bin/python scripts/test-package.py
build/packaging-venv/bin/python scripts/package.py package build/packages \
  --arch "$(uname -m)" --version 0.1.0 --build 0.1.0 \
  --commit "$(git rev-parse HEAD)" --adhoc
```

Use the checked-out version in place of `0.1.0` after a version bump. The
output directory must not already contain that asset. Packaging validates
the bundle first, creates a compressed HFS+ UDZO image, mounts it read-only,
and checks the bundled app, `/Applications` shortcut, installation text,
and actual Finder icon-view layout. It detaches the image even when a
validation fails. You can repeat the gate with `validate-dmg` in place of
`package`, passing the DMG path instead of an output directory. Use
`validate-app` with an app path for bundle-only verification.

The package tests mutate real signed bundles and real disk images. They
check rejection of wrong metadata/architecture, absent resources/notices,
invalid signatures, changed bytes/source identity, missing app/instructions,
incorrect shortcuts, and overlapping installer icons.

## Bundled licenses and manual checks

The app includes TOMLKit 0.6.0, its vendored toml++ 3.4.0, and the latter's
Hoehrmann UTF-8 decoder MIT notices in `ThirdPartyNotices.txt`. Its four
WOFF2 resources are Silkscreen and
JetBrains Mono, regular and bold; `FontLicenses.txt` includes their copyright
notices and SIL Open Font License 1.1 from the linked upstream sources.
`ds-store` and `mac-alias` are build-time tools, not bundled app dependencies.

Automated mount and signature checks don't exercise Gatekeeper, app launch,
Screen Recording, Accessibility, or permission retention across updates.
Before advertising installation, test browser-quarantined downloads and
drag installation, launch approval, capture, editing, copy/save, and upgrade
permissions on both processors, including macOS 14. A newer ARM host cannot
establish native Intel execution or macOS 14 first-launch behavior.
