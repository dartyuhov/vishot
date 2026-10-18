# Release operations

Merging a Release Please PR approves one regular Vishot release. The
`Publish release` workflow builds that PR's exact merge commit on native Apple
Silicon and Intel runners, stages a complete draft, and publishes it only after
validating the uploaded bytes. Ordinary main-branch merges don't publish.

## Configure publication

Configure these prerequisites before approving a release:

1. Install the release GitHub App on this repository with **Contents**,
   **Pull requests**, and **Issues** read/write permissions. The release PR
   workflow needs all three; publication requests only Contents/Issues write
   and Pull requests read.
2. Set repository variable `RELEASE_APP_CLIENT_ID` and repository secret
   `RELEASE_APP_PRIVATE_KEY`. Set variable `RELEASE_APP_BOT_LOGIN` to the exact
   App bot login, including `[bot]`, for example, `vishot-release[bot]`.
3. Enable Actions and the native runner labels `macos-15` and
   `macos-15-intel`. Both must provide Xcode 16.4 and Swift 6.1.2. Private
   repository runner usage requires available account minutes or billing.
4. Require the repository's PR checks on protected `main`, retain validated
   Conventional Commit titles when squash merging, and restrict direct pushes
   and tag mutation. The publisher never force-updates a tag.

The App token is repository-scoped, short-lived, and created only after both
package jobs succeed. Read-only approval and packaging jobs receive no App
secret. PR workflows never receive publishing credentials. App-authenticated
publication emits GitHub release events for downstream distribution workflows;
events created with `GITHUB_TOKEN` don't trigger ordinary workflows.

## Approve and observe a release

Review the bot-managed PR before merging it:

1. Confirm its version, changelog, and checks. Release Please manages
   `version.txt`, `.release-please-manifest.json`, and both version fields in
   `Resources/Info.plist`. The first regular version is `0.1.0`.
2. Squash merge the release PR into `main`. This is the release approval.
3. Observe **Actions → Publish release**. Approval checks the PR's author,
   repository, managed branch, merge SHA, main ancestry, lifecycle label,
   Release Please title/body, and version files at that exact SHA.
4. Wait for both native package jobs. Each runs Swift tests, signs the app
   ad hoc, validates its bundle and mounted DMG, and uploads artifacts from
   the same source commit. Publication consumes artifacts only from this run.
5. Confirm the regular release contains the six assets listed below and the
   release PR has `autorelease: tagged` instead of `autorelease: pending`.

For each of `arm64` and `x86_64`, the release contains:

- `Vishot-VERSION-ARCH.dmg`.
- `Vishot-VERSION-ARCH.dmg.sha256`, with a SHA-256 and the exact DMG filename.
- `Vishot-VERSION-ARCH.dmg.json`, with the checksum, architecture, version,
  build, source commit, and `Package.resolved` checksum, plus toolchain details.

The publisher validates the full local asset set before writing anything. It
pins `vVERSION` to the approved commit, stages a draft with a PR/source marker,
and downloads the staged assets through the authenticated release asset API.
Only a complete set with matching checksums and source manifests can pass the
single `draft: false` update, with `prerelease: false` and `make_latest: true`.
The draft remains hidden from normal release/download discovery on failure.

Release Please uses `skip-github-release`; it doesn't publish or tag behind
this gate. Publication changes the PR labels only after success. A pending
merged release PR blocks Release Please from opening the next release PR.

## Resume a failed release

Use the original merged release PR number for every retry. Don't merge another
PR, calculate a replacement version, or create a replacement tag.

1. Inspect the failed job. Fix infrastructure or tooling failures through the
   normal contribution flow. Changes to the app itself need a later release;
   a retry always builds the original approved merge commit.
2. For a transient failure, use **Re-run all jobs** on the original run. This
   regenerates both packages and doesn't depend on retained artifacts.
3. To use updated publication tooling or recover a canceled/expired run, open
   **Actions → Publish release → Run workflow**, select `main`, and enter the
   original merged release PR number in `release_pr`. A dispatch on another
   branch doesn't run. This path uses trusted main-branch workflow/tooling and
   resolves the original approved source and version through GitHub again.
4. Confirm the release and lifecycle label after completion. If a newer
   regular release is already public, an older retry fails as stale.

A draft retry locates releases through the paginated release list, retains
matching assets, and replaces only incomplete or changed draft assets. This
also recovers GitHub upload failures that leave `starter` assets, partial
uploads, and interrupted responses. Rebuilt DMGs can differ because of image
timestamps; draft staging reconciles them into one validated set.

A completed-release rerun validates the original public bytes and tag. It
doesn't replace public assets, alter the release, or move the latest pointer.
It can finish interrupted label updates. If the public set is incomplete or
corrupt, or the tag points at a different commit, the run fails for investigation
instead of silently repairing public downloads. Don't move a published tag or
replace published assets; ship a new approved version for corrections.

All publication runs share one concurrency group, without canceling active
runs. GitHub doesn't guarantee queue order and can replace pending runs. The
explicit dispatch path recovers those approvals. The publisher checks all
public regular release versions and source ancestry before staging and again
before publication so an older queued run can't move latest backward. Keep
manual/API publication outside this serialized workflow disabled operationally;
GitHub's release API doesn't offer a compare-and-swap visibility update.

## Verify the boundary locally

Run these checks with Node 22 or newer before merging publication changes:

```sh
npm ci --prefix scripts/release --ignore-scripts
npm test --prefix scripts/release
```

The suite exercises actual locked Release Please generation and the production
REST adapter with controlled transports. It covers exact PR/version binding,
both source manifests, missing assets, bad checksums, draft repair, 502 upload
failures, failed/lost publication responses, paginated draft lookup, immutable
public reruns, conflicting tags, and early/late stale-run guards. Workflow
contracts check credential isolation, package dependencies, and dispatch scope.

Hosted event delivery, App installation permissions, protected-branch settings,
native runner availability, and real GitHub publication still require an
authorized hosted verification. Native installation checks are documented in
the [release distribution spec](specs/release-distribution.md). Repository
visibility and first public release execution are separate launch decisions.
