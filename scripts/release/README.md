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

The App token is required: PRs created with `GITHUB_TOKEN` do not trigger ordinary
PR workflows. App-authored release PRs trigger the title and tooling checks, plus
the App/Site checks once their required-check workflow gates are integrated.
Fork PR title/tooling validation uses read-only permissions and no App secret.

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
