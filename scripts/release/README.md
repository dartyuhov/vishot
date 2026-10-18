# Release PR tooling

Release Please owns app version selection, `version.txt`,
`.release-please-manifest.json`, and the generated `CHANGELOG.md`. The workflow
uses the same locked Release Please package as the contract tests.

## Release intent

Use Conventional Commit PR titles and retain the title when squash merging.
Accepted types are `feat`, `fix`, `docs`, `chore`, `refactor`, `perf`, `test`,
`build`, `ci`, and `revert`. Scopes and `!` breaking markers are optional.

- `fix: repair clipboard output` requests a patch.
- `feat(capture): add a selection mode` requests a minor.
- `feat(settings)!: replace the settings format` requests a major, including
  before `1.0.0`. A `BREAKING CHANGE:` commit footer also requests a major.
- `docs: explain installation` and ordinary `chore`, `ci`, `build`, `test`, or
  `refactor` maintenance do not independently request a release. Release Please
  also recognizes `perf` as a patch and breaking markers on maintenance commits.
- `fix(deps): update an app dependency`, `fix(packaging): include missing fonts`,
  and `fix(release): repair publication` explicitly request app patches.
- Changes confined to `site/`, `docs/`, or Markdown documentation anywhere in
  the repository are excluded before version selection, even
  with `feat` or breaking titles. Use `feat(site): add a download chooser` for a
  site feature. Keep site and app changes in separate PRs when their release
  intent differs. A PR touching app files is evaluated as one squash commit.

The first release is explicitly `0.1.0`, with no prerelease suffix. The checked-in
`0.0.0` manifest entry is an unreleased bootstrap sentinel, not a published
version. `initial-version` applies only before the first release; it does not
pin subsequent versions. The bootstrap SHA excludes history predating this
release setup. After launch, `fix` advances `0.1.0` to `0.1.1`, `feat` advances
`0.1.x` to `0.2.0`, and a breaking change advances it to `1.0.0`.

Main-branch merges accumulate in one managed release PR. The highest-impact
unreleased app change wins. Contributors don't edit versions or create tags.
The `Release PR` workflow runs `node release-pr.mjs`; it creates no
tag or GitHub release. Merging the release PR supplies the version and changelog
for the separate, validated publication workflow.

Release Please 17.11.2's `exclude-paths` accepts directory prefixes, not exact
files or glob patterns. The adapter removes Markdown paths (`.md`,
`.markdown`, `.mdown`, `.mkd`, and `.mdx`, case-insensitively) from the SCM file
lists before Release Please applies its all-files exclusion. It uses each
historical commit's file list, so new and deleted documentation is covered
without maintaining a filename list.
It preserves commit identities and titles; Release Please still owns version
selection, bootstrap boundaries, and PR updates. Mixed app changes remain
eligible for release.

## GitHub App prerequisite

Install a GitHub App on this repository with **Contents**, **Pull requests**, and
**Issues** read/write permissions. Configure repository variable
`RELEASE_APP_CLIENT_ID` and repository secret `RELEASE_APP_PRIVATE_KEY`. The
workflow requests only those permissions and scopes its short-lived installation
token to this repository. The action revokes the token after the job.

The App token delivers automatic release-PR checks without the `GITHUB_TOKEN`
approval restriction. Current GitHub behavior permits approval-required runs for
`GITHUB_TOKEN`-authored PR `opened`, `synchronize`, and `reopened` events; a writer
must approve those runs. Other PR events, including `edited`, don't trigger runs
with that token. `workflow_dispatch` and `repository_dispatch` are exceptions to
the general recursive-event restriction. See GitHub's
[workflow triggering documentation](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow).
App-authored release PRs trigger all five required checks automatically.
Fork PR validation uses read-only permissions and no App secret; GitHub can still
require maintainer approval before running a fork contributor's workflows.

The exact required names and the explicit repository-settings procedure are in
[CONTRIBUTING.md](../../CONTRIBUTING.md). The settings CLI prints its plan without
calling GitHub unless you pass `--apply OWNER/REPO PR_NUMBER`.

## Verification and publication integration

Run the focused behavioral suite with Node 22 or newer:

```sh
npm ci --prefix scripts/release --ignore-scripts
npm test --prefix scripts/release
```

Tests invoke the actual Release Please manifest API with only the external SCM
boundary substituted. They verify generated PR versions, changelog/version
updates, path exclusion, aggregation, first-launch behavior, and updating one
existing PR. Workflow contracts check title-edit events and credential scope.

Publication and site readiness share `site/release-contract.js` for the six asset
names and manifest identity checks. The site reads only small sidecars and the
source lockfile, checks their contents against GitHub's asset digests, and
requires cask checksums to match the DMG digests. Missing GitHub digest metadata
fails closed. Public requests carry no credentials, and optional star requests
use a separate cache. DMG bytes are hashed by publication and Homebrew tooling.

Python packaging and Homebrew keep independent validation because they run
without Node. The cross-boundary test sends one controlled package through the
actual Python cask CLI, JavaScript publication validator, and site readiness
boundary, then changes each provenance field to check that all reject it.

The publication workflow must build the merged release PR's exact source commit,
read `version.txt`, and validate both architecture assets before publication.
After successful publication, it must remove `autorelease: pending` and add
`autorelease: tagged` to that merged PR. Release Please deliberately blocks new
release PR creation while a merged PR retains the pending label. Leave it
pending on failure so publication can retry before another release is approved.

After configuring the App and required checks, verify in GitHub that a bot-created
release PR receives all required results, and editing a fork PR title reruns
validation. Local contract tests cannot observe hosted event delivery or
repository protection settings.
