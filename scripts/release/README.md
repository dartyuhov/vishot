# Release PR tooling

Release Please owns app version selection, `version.txt`,
`.release-please-manifest.json`, and the generated `CHANGELOG.md`. The workflow
uses the same locked Release Please CLI package as the contract tests.

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
- Changes confined to `site/` or `docs/` are excluded by Release Please, even
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
The `Release PR` workflow runs only `release-please release-pr`; it creates no
tag or GitHub release. Merging the release PR supplies the version and changelog
for the separate, validated publication workflow.

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
