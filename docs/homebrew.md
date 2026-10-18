# Homebrew cask generation

Use `scripts/homebrew/cask.py` to generate the owned-tap cask from the same
complete release package used for direct downloads. It emits real Homebrew
Ruby syntax, requires macOS 14 (Sonoma) or newer, selects `arm64` or
`x86_64`, verifies the matching SHA-256, and installs `Vishot.app` into
Applications. It declares a regular version so Homebrew can detect upgrades.

The cask retains Homebrew's default quarantine behavior. It has no install
hooks, security overrides, or automatic in-app update declaration. Direct
downloads and Homebrew installations retain normal Gatekeeper checks.

## Ownership and public availability

Read-only GitHub API checks on October 18, 2026, establish these prerequisites:

- The authenticated account is `dartyuhov`, matching the proposed tap owner.
- `dartyuhov/vishot` belongs to that account, and the account has admin access.
  The repository is **private**, and its releases API returns an empty list.
- `dartyuhov/homebrew-tap` returns HTTP 404 for that account. The proposed tap
  is not confirmed accessible or available. A 404 does not prove that a
  repository is available to create.

The proposed `dartyuhov/tap` name resolves to the GitHub repository
`dartyuhov/homebrew-tap`. Before publishing an installation command, separately
authorize and establish a public owned tap, confirm access, and publish a
complete public app release. No remote creation, push, release publication,
or visibility change is part of this tooling. There is no checked-in
`0.1.0` cask with invented checksums.

## Input contract

The generator accepts downloaded assets and GitHub REST API JSON objects.
Both the CLI and the importable `generate_cask` function use this boundary:

- `packages`: a directory containing both `Vishot-<version>-arm64.dmg` and
  `Vishot-<version>-x86_64.dmg`, with `.dmg.sha256` and `.dmg.json` sidecars.
  Filenames and checksum text follow the [package contract](packaging.md).
- `release`: the release API object with `tag_name`, `draft`, `prerelease`,
  `published_at`, and `assets`. Only published regular `v<major>.<minor>.<patch>`
  tags qualify. Each required asset must be uploaded, have its exact
  versioned GitHub download URL, and match the downloaded byte size. Duplicate
  asset names fail validation. Other release assets can coexist.
- `repository`: the repository API object. `full_name` must be
  `dartyuhov/vishot`, `private` must be `false`, and `visibility` must be
  `public`.
- `source_commit`: the full lowercase commit SHA resolved from the release
  tag by the caller. Don't use a branch name or assume `target_commitish`
  is a resolved SHA.
- `lockfile`: `Package.resolved` from that exact source commit.

For each architecture, the generator hashes the DMG bytes and compares the
digest with the checksum sidecar and manifest. When GitHub supplies an asset
`digest`, it also verifies that digest for the DMG and both sidecars. The
manifest must match the asset name, architecture, version, source commit,
and lockfile digest. Both manifests must have the same numeric build version
and nonempty Xcode and Swift provenance fields. Toolchain descriptions can
differ between native hosts. Missing, malformed, truncated, or inconsistent
inputs fail before the generator emits any cask source.

These checks consume the output of the native packaging gate; they don't
replace its mounted-image, Mach-O, bundle, signature, and installer-layout
validation. Manifests establish consistency, not cryptographic attestation.
The caller must obtain API metadata, resolve the tag, and download assets
from the trusted release. Passing fabricated public metadata is not evidence
of public availability.

## Generate and validate a candidate

Use Python 3.11 or newer and Homebrew on macOS. Prepare the input files above
in `build/homebrew/`, then generate a candidate with the exact resolved source
SHA in `SOURCE_COMMIT`:

```sh
python3 scripts/homebrew/cask.py generate \
  --packages build/homebrew/packages \
  --release build/homebrew/release.json \
  --repository build/homebrew/repository.json \
  --source-commit "$SOURCE_COMMIT" \
  --lockfile build/homebrew/Package.resolved > build/homebrew/vishot.rb

python3 scripts/homebrew/cask.py validate \
  --packages build/homebrew/packages \
  --release build/homebrew/release.json \
  --repository build/homebrew/repository.json \
  --source-commit "$SOURCE_COMMIT" \
  --lockfile build/homebrew/Package.resolved \
  --cask build/homebrew/vishot.rb
```

`generate` writes only cask source to stdout. Errors go to stderr with a
nonzero exit status. `validate` first requires byte-for-byte agreement with
the regenerated candidate, then loads that trusted Ruby through Homebrew's
actual cask DSL under simulated ARM and Intel Sonoma systems. It returns
Homebrew metadata as JSON keyed by `arm` and `intel`. It never downloads or
installs the generated cask. The helper evaluates Ruby: don't use it to
inspect arbitrary untrusted casks.

For the later automatic tap updater, import `generate_cask` and
`validate_cask`, or invoke the same CLI. Stage output outside the tap's
working `Casks/vishot.rb`; shell redirection truncates its target before the
generator runs. Replace the working cask only after successful generation
and validation. The updater must separately enforce trusted publication,
tap-only credentials, serialization, monotonic versions, and recoverable
retries. This generator performs no network calls or tap mutations.

## Controlled verification

Run the package-boundary suite, including Homebrew's actual parser:

```sh
VISHOT_TEST_HOMEBREW=1 python3 -B -m unittest discover \
  -s scripts/homebrew -p 'test_*.py' -v
```

The read-only `Homebrew tooling` workflow runs this command on macOS. The
required `Release tooling` result also runs it on every PR, so Homebrew
validation failures block that required result. Without
`VISHOT_TEST_HOMEBREW=1`, the pure package tests run and the Homebrew test is
explicitly skipped. With the variable set, missing Homebrew fails the test.

Tests create temporary `1.2.3` fixtures with explicitly labeled non-DMG bytes
and compute their real digests. They check both architecture URLs, versions,
checksums, macOS requirements, and the Applications artifact using Homebrew's
DSL. They reject changed casks, missing assets or manifest fields, corrupt
bytes, mismatched provenance, draft/private releases, duplicate assets, and
wrong download URLs. Fixture source is never committed as a usable cask or
represented as a published installer. Architecture simulation verifies
metadata selection, not native execution.

## Launch gate

Real public installation and upgrade remain blocked by the private app
repository, absence of a complete release, and unconfirmed tap availability.
After those prerequisites are resolved, install and upgrade from the public
tap on supported Apple Silicon and Intel Macs, including macOS 14. Verify
quarantine, first-launch approval, capture permissions, and permission
retention using real installers. Local ARM metadata simulation does not
establish native Intel or macOS 14 behavior. Record those hardware checks
at the final launch gate before enabling public installation controls.

The implementation follows the current
[Homebrew cask cookbook](https://docs.brew.sh/Cask-Cookbook) for architecture
selection, checksums, `depends_on`, and `app` stanzas, and Homebrew's
[cask security model](https://docs.brew.sh/Homebrew-Security-and-Supply-Chain#casks-have-a-different-trust-model).
