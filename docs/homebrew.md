# Homebrew distribution

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

The automatic updater uses these same `generate_cask` and `validate_cask`
interfaces. It stages the candidate outside the tap and validates it before
cloning or changing the tap. The generator itself performs no network calls
or tap mutations.

## Configure automatic updates

The local machinery is ready for setup; these prerequisites have not been
configured or verified against a public remote:

1. Separately authorize and establish public `dartyuhov/homebrew-tap`, confirm
   ownership, and initialize its default branch as `main` with a README.
   `Casks/vishot.rb` can be absent for the first update. Don't seed it with
   invented checksums or a bootstrap version.
2. Create a **separate tap GitHub App** with only **Contents: read and write**
   and implicit metadata access. Install it only on `homebrew-tap`, using
   selected repositories. It needs no app-repository installation, Actions,
   Issues, Pull requests, organization, or administration permissions.
3. In the app repository's Actions configuration, set variable
   `TAP_APP_CLIENT_ID` and secret `TAP_APP_PRIVATE_KEY`. Keep these separate
   from the release App credentials. The workflow mints a short-lived token
   scoped explicitly to owner `dartyuhov`, repository `homebrew-tap`, and
   Contents write; the token action revokes it after the job.
4. Permit this App to push normal fast-forward commits to tap `main` without
   recurring PR approval. Keep other writers controlled, prohibit force
   pushes, and don't delete or manually downgrade the cask. If tap rules
   prohibit direct bot commits, configure a narrowly scoped rule for this
   App under separate settings authorization. No settings change is automated.
5. Make the app repository public under separate authorization, configure
   the [publication prerequisites](release-operations.md#configure-publication),
   and publish a complete regular release through that gate. Land both
   workflows on app `main` before testing hosted delivery.

`Publish release` calls `Update Homebrew tap` directly after its publication
job succeeds, passing the approved exact `vVERSION`. It doesn't depend on
`release.published` delivery, so `GITHUB_TOKEN` event suppression cannot skip
this handoff. An app publication failure prevents the tap job from running.
A tap failure marks the workflow failed but leaves the completed app release
available. Ordinary PR checks receive neither App secret.

The updater runs only in `dartyuhov/vishot` on `main`, checks out trusted
`main` tooling, and accepts only a regular version tag as data. Public release
API and download requests are unauthenticated; a private release cannot pass
using a privileged token. The tap token is supplied only through ephemeral,
tap-URL-scoped Git configuration, not persisted checkout credentials or URLs.

## Automatic validation and atomic advancement

The updater re-fetches repository metadata, the exact release, all paginated
assets, the tag's resolved commit, and `Package.resolved` at that commit.
It downloads both DMGs and four sidecars from their exact versioned public
URLs, then uses the generator's complete checksum/provenance contract and
Homebrew's real ARM/Intel DSL validation. It rechecks release identity, source,
and asset metadata after validation. It never trusts workflow artifacts or
`target_commitish` as the public download evidence.

All automatic and dispatched updates share `homebrew-tap-update` concurrency
with active-run cancellation disabled. GitHub doesn't guarantee queue order
and can replace a pending run; explicit dispatch recovers such a run. Each
attempt fetches tap `main` again and compares numeric major/minor/patch
versions. Older candidates fail as stale. Equal versions succeed without a
commit only if the whole cask matches; conflicting equal-version metadata
fails for investigation. Unparseable versions and symlink paths fail closed.

Only `Casks/vishot.rb` is committed. One normal, non-force Git push advances
the branch atomically. A concurrent branch update rejects that push; the
updater retries from fresh remote state and repeats version checks, preserving
unrelated changes. There are at most three pushes and a final readback to
reconcile a lost successful response. No error path rolls the tap back or
modifies an app release, tag, asset, or latest pointer.

## Recover a tap update

Use the independent workflow after fixing access, service, or tooling errors:

1. Inspect the failed step, its recovery summary, and tap `main`. If Git
   disconnected after a push, the cask may already be current; don't revert it.
2. Open **Actions → Update Homebrew tap → Run workflow**, select **main**,
   and enter the exact completed release tag, for example, `v1.2.3`.
3. Confirm the tap cask version and both checksums after the run. A repeated
   successful update is a no-op. A newer installed cask causes an older retry
   to fail as stale; don't force it backward.

Dispatching this workflow doesn't build, package, or republish Vishot. Don't
rerun app publication solely to repair the tap. Fix corrupt or incomplete
public app assets by publishing a new approved app version, rather than
replacing completed release assets. Resolve conflicting same-version tap
metadata through an investigated correction; the updater refuses to overwrite
it silently.

After public availability is verified, users can run:

```sh
brew install --cask dartyuhov/tap/vishot
brew update
brew upgrade --cask dartyuhov/tap/vishot
```

These are prepared commands, not evidence that the tap exists today. Quit
Vishot before upgrading and follow the README's permission checks afterward.

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

Updater tests additionally exercise the production public HTTP adapter with
controlled responses and real local bare Git repositories. They cover missing
assets, checksum mismatch, paginated assets, moving source identity, public
visibility, download failure, rejected pushes, monotonic versions, conflicting
same-version content, a paused old writer losing to a newer writer, lost push
responses, and idempotent recovery. The end-to-end controlled path runs the
real generator and Homebrew parser before pushing the cask. Its app HTTP
boundary rejects every non-GET request. These fixtures don't establish hosted
event delivery, real App access, or public tap installation.

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
