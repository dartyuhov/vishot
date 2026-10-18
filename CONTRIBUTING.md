# Contributing to Vishot

Open a pull request with a Conventional Commit title, run the checks relevant to
your change, and describe any manual macOS verification. The maintainer squash
merges validated PRs. Release Please manages app versions and the changelog.

## Choose a PR title

Use `type: description` or `type(scope): description`. Accepted types are `feat`,
`fix`, `docs`, `chore`, `refactor`, `perf`, `test`, `build`, `ci`, and `revert`.
Add `!` before the colon for an explicitly breaking change. The title check runs
when you open, edit, reopen, update, or mark a PR ready for review.

After the first release, app release intent follows these examples:

| Title | Result from 0.1.0 |
| --- | --- |
| `fix: repair clipboard output` | Patch: 0.1.1 |
| `perf(capture): reduce export latency` | Patch: 0.1.1 |
| `feat(capture): add a selection mode` | Minor: 0.2.0 |
| `feat(settings)!: replace the settings format` | Major: 1.0.0 |
| `docs: clarify keyboard shortcuts` | No independent app release |
| `chore: tidy development scripts` | No independent app release |
| `feat(site): add a download chooser` confined to `site/` | No app release |

Breaking changes request a major even before 1.0. Use `!` in the PR title so
release intent is validated and survives a squash merge. Release Please also
recognizes a `BREAKING CHANGE:` commit footer, but PR bodies and individual
commit messages aren't automatically retained by the configured squash defaults.

Ordinary `build`, `ci`, `test`, `refactor`, `chore`, and `revert` maintenance
doesn't independently request a release. Use a breaking marker if that work is
incompatible. Use `fix` when a dependency, packaging, or workflow correction must
ship an app patch, for example:

- `fix(deps): update an app dependency`
- `fix(packaging): include missing fonts`
- `fix(release): repair publication`

Changes confined to `docs/` or `site/` are excluded from app releases even with
feature or breaking titles. Root documentation uses a non-releasing `docs` title.
Keep app and site changes in separate PRs when their release intent differs: a
mixed PR is evaluated as one squash commit. Non-releasing work can accompany the
next app release.

## Verify your change locally

Use macOS 14 or newer and Swift 6 for app development. CI pins Xcode 16.4 with
Swift 6.1.2 and tests native Apple Silicon and Intel packages. Use Node 24 for the
site and release tooling. Run these commands from the repository root:

```sh
swift test --force-resolved-versions
npm ci --prefix site
npm test --prefix site
npm ci --prefix scripts/release --ignore-scripts
npm test --prefix scripts/release
```

For app changes, build and launch the installed bundle with
`./scripts/build.sh install`. Local builds default to your stable
`Apple Development` identity; override `VISHOT_SIGN_IDENTITY` if needed. For a
certificate-free packaging check, use `VISHOT_SIGN_IDENTITY=- bash scripts/build.sh`
and `python3 scripts/test-package.py` after installing the hash-locked tools from
`scripts/packaging-requirements.txt`. CI uses ad-hoc signing and needs no Apple
account or signing secret. Don't expect ad-hoc rebuilds to preserve permissions.

For changes affecting the app, record the macOS version, architecture, and manual
results in your PR. Verify these behaviors on the installed app:

- Open the menu-bar app and invoke the default `⇧⌘S` shortcut.
- Approve Screen Recording, follow any restart request, and paste a capture.
- Select windows, displays, and regions; enable Accessibility for element hints
  and keyboard window raising.
- Add annotations, crop, undo, copy, and save; exercise capture history.
- Check cancellation, multiple displays, and non-Latin keyboard layouts when
  relevant to your change.

For installer/release changes, test browser-downloaded, quarantined DMGs on Apple
Silicon and Intel, including macOS 14 coverage. Check the Applications shortcut,
drag installation, ejecting, **Privacy & Security → Open Anyway**, first capture,
and replacing an older app after quitting it. Record permission prompts on both
first install and upgrade; don't assume approval survives an ad-hoc update.
Identify unavailable hardware coverage explicitly.

## Land a validated PR

All PRs, including docs-only, site-only, forks, and bot release PRs, run the same
five required check names:

- `App tests`: locked Swift tests.
- `Site tests`: the site suite, in the `Site` workflow.
- `PR title`: Conventional Commit title validation, including title edits.
- `Release tooling`: title, version, workflow, and settings contracts, plus
  Homebrew package and real cask DSL validation on macOS.
- `Package checks`: an always-running gate that requires both native DMG jobs
  to succeed; failure, cancellation, or skipping cannot pass the gate.

These workflows use read-only repository permissions and no release secrets.
GitHub can require approval before running fork workflows. Don't add skip-CI
markers or PR path filters that leave required checks pending. `Site` retains
its main-push path filter for `site/**` and its workflow file so Railway's
**Wait for CI** deployment dependency still waits for the site suite.

Update your branch when required, wait for every check, and use **Squash and
merge**. Keep the validated PR title as the final squash title, even if GitHub
offers an editable field. Individual commit titles aren't the release contract.
The intended main protection applies to administrators too, requires a PR and
up-to-date successful checks, blocks force-pushes and deletion, and requires no
other approving reviewer for the solo maintainer. See the setup status below;
these settings aren't active merely because this guide describes them.

## Approve a release

Ordinary main merges accumulate in one bot-managed release PR; they don't
immediately publish the app. The highest-impact unreleased app change selects
the next bump. The first regular release is explicitly `0.1.0`; the checked-in
`0.0.0` is an unreleased bootstrap sentinel.

Don't edit `version.txt`, the release manifest, generated version metadata, or
`CHANGELOG.md` for an ordinary contribution, and don't create release tags.
Review the bot's release PR, its version, changelog, and all required checks.
Merging that PR is the maintainer's release approval. The publication workflow
must build the exact merged source on both architectures, validate both DMGs and
checksums, and only then publish one complete regular GitHub release. Packaging
PR checks alone don't authorize publication. A failed publication must remain
retryable without replacing an already completed release.

The `Release PR` workflow uses a repository-scoped GitHub App installation token.
Install that App with **Contents**, **Pull requests**, and **Issues** read/write
permissions, then configure variable `RELEASE_APP_CLIENT_ID` and secret
`RELEASE_APP_PRIVATE_KEY`. Don't give those credentials to ordinary PR jobs.

Don't replace the App token with `GITHUB_TOKEN`: current GitHub behavior creates
approval-required runs for token-authored PR `opened`, `synchronize`, and
`reopened` events, and doesn't create runs for other PR activities such as
`edited`. App tokens support automatic PR checks without that approval step.
`workflow_dispatch` and `repository_dispatch` are exceptions to the general
token recursion restriction. See the
[release tooling guide](scripts/release/README.md) for details and the upstream
documentation.

## Configure repository settings

An administrator must execute this procedure explicitly after the workflow
branch exists remotely with completed checks. The settings script never runs in
CI and prints the exact REST API payloads without network access by default:

```sh
node scripts/release/repository-settings.mjs
```

On October 18, 2026, read-only inspection of `dartyuhov/vishot` confirmed a private
repository and ADMIN access. GitHub returned HTTP 403 for main protection:
“Upgrade to GitHub Pro or make this repository public to enable this feature.”
Merge, rebase, and squash were all enabled, with `COMMIT_OR_PR_TITLE` and
`COMMIT_MESSAGES` squash defaults. No protection or merge settings were changed.
The private-repository plan restriction is an external blocker, not a missing
ADMIN grant. Visibility and paid-plan changes require a separate owner decision.

When that blocker is resolved, complete these steps:

1. Publish the workflow branch and open a PR against `main` under separate push
   authorization. Wait for all five named checks on its current commit. Run the
   script from that same local branch/commit. This task doesn't publish it.
2. Authenticate `gh` to github.com with repository administration write access
   and checks/PR read access. A fine-grained token needs **Administration**
   read/write, **Checks** read, **Pull requests** read, and **Contents** read.
   Repository ADMIN access alone doesn't override token or plan restrictions.
3. Review the printed plan. The script replaces main's classic protection
   configuration; review existing rulesets and additional restrictions before
   applying it. It requires up-to-date checks from the GitHub Actions App
   (`15368`), enforces administrators, requires a PR with zero approvals, blocks
   force-pushes/deletion, and requires linear history. Repository settings allow
   only squash merges and default the title to `PR_TITLE` with a `BLANK` body.
4. Run the explicit mutation command, substituting the actual open PR number:

   ```sh
   node scripts/release/repository-settings.mjs --apply dartyuhov/vishot PR_NUMBER
   ```

   The script checks plan access, a same-repository remote branch at local HEAD,
   and successful named checks on the PR head or test-merge commit before either
   write. A protection HTTP 403 aborts both writes. The two writes aren't atomic;
   inspect both settings and rerun after resolving any partial failure.
5. Confirm **Settings → General → Pull Requests** uses squash only and the PR
   title, and **Settings → Branches** protects `main` with the exact five check
   names above, administrator enforcement, zero approvals, and no force-push or
   deletion. Confirm any rulesets don't add another review requirement or bypass.

## Verify hosted behavior after setup

Local contract tests check workflow and settings behavior, but can't prove hosted
event delivery or protection enforcement. After authorized remote setup, record
PR URLs, commit SHAs, check results, and settings readback for these checks:

1. Open docs-only, site-only, and app PRs and confirm all five checks complete.
   Use an approved fork PR to confirm the ordinary checks require no secrets.
2. Change a PR title to an invalid title, observe `PR title` fail, then correct
   it and observe a fresh successful validation.
3. Let the configured GitHub App create or update a release PR and confirm all
   five required results arrive automatically on its latest commit.
4. Confirm a failing required check prevents merging and a corrected, current
   PR can squash merge without a second reviewer. Inspect protection readback
   for administrator enforcement and blocked force-push/deletion; don't test
   these by destructively rewriting `main`.
5. Confirm a site change on `main` runs `Site` and Railway waits for its success.

These hosted checks and protection activation remain pending while this branch
is local and the private-repository protection API returns 403. Local passing
tests don't represent configured remote protection or a published release.
