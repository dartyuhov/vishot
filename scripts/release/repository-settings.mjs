import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

// GitHub.com GitHub Actions App ID; don't accept a user-authored status instead.
export const actionsAppID = 15368;
export const requiredChecks = ['App tests', 'Site tests', 'PR title', 'Release tooling', 'Package checks'];
export const plan = {
  repository: {
    allow_squash_merge: true, allow_merge_commit: false, allow_rebase_merge: false,
    squash_merge_commit_title: 'PR_TITLE', squash_merge_commit_message: 'BLANK',
  },
  protection: {
    required_status_checks: {
      strict: true, contexts: [],
      checks: requiredChecks.map(context => ({ context, app_id: actionsAppID })),
    },
    enforce_admins: true,
    required_pull_request_reviews: {
      required_approving_review_count: 0, require_code_owner_reviews: false,
      dismiss_stale_reviews: true, require_last_push_approval: false,
    },
    restrictions: null,
    required_linear_history: true,
    allow_force_pushes: false,
    allow_deletions: false,
  },
};

function gh(method, endpoint, body) {
  const args = ['api', '--hostname', 'github.com', '--method', method, endpoint];
  if (body) args.push('--input', '-');
  return JSON.parse(execFileSync('gh', args, {
    input: body ? JSON.stringify(body) : undefined, encoding: 'utf8',
  }));
}

export function applySettings(repo, number, head, api = gh) {
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo) || !/^\d+$/.test(number)) {
    throw new Error('Use --apply OWNER/REPO PR_NUMBER for an open same-repository PR.');
  }
  const base = `repos/${repo}`;
  const repository = api('GET', base);
  if (!repository.permissions?.admin || repository.default_branch !== 'main') {
    throw new Error('Requires repository ADMIN access and main as the default branch.');
  }
  // A 404 means protection has not been configured. A 403 (including plan
  // restrictions) must abort before either write; don't mistake it for absence.
  try {
    api('GET', `${base}/branches/main/protection`);
  } catch (error) {
    if (!/\(HTTP 404\)/.test(error.stderr?.toString() ?? '')) throw error;
  }
  const pr = api('GET', `${base}/pulls/${number}`);
  if (pr.state !== 'open' || pr.base.ref !== 'main' ||
      pr.head.repo?.full_name !== repo || pr.head.sha !== head) {
    throw new Error('PR must be open against main, in this repository, at local HEAD.');
  }
  const branch = api('GET', `${base}/branches/${encodeURIComponent(pr.head.ref)}`);
  if (branch.commit.sha !== head) throw new Error('Remote branch must exist at local HEAD.');
  const runsByCommit = [];
  for (const sha of new Set([pr.head.sha, pr.merge_commit_sha].filter(Boolean))) {
    // Only five required names; request the latest run of each check name.
    runsByCommit.push(api('GET', `${base}/commits/${sha}/check-runs?filter=latest&per_page=100`).check_runs);
  }
  for (const name of requiredChecks) {
    // GitHub gives the test-merge result precedence when that check exists.
    const runs = [...runsByCommit].reverse().find(runs =>
      runs.some(run => run.name === name && run.app?.id === actionsAppID)) ?? [];
    const latest = runs.filter(run => run.name === name && run.app?.id === actionsAppID)
      .sort((a, b) => b.id - a.id)[0];
    if (latest?.status !== 'completed' || latest.conclusion !== 'success') {
      throw new Error(`Remote PR needs a completed successful GitHub Actions check: ${name}`);
    }
  }
  api('PUT', `${base}/branches/main/protection`, plan.protection);
  api('PATCH', base, plan.repository);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  if (!args.length) {
    console.log(JSON.stringify(plan, null, 2));
  } else if (args.length === 3 && args[0] === '--apply') {
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
    applySettings(args[1], args[2], head);
    console.log('Applied main protection and squash-only settings. Verify both in GitHub.');
  } else {
    throw new Error('Usage: node scripts/release/repository-settings.mjs [--apply OWNER/REPO PR_NUMBER]');
  }
}
