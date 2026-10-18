import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function affected(paths) {
  paths = paths.filter(p => !/\.md$/i.test(p));
  const workflow = p => p.startsWith('.github/');
  const ci = p => p.startsWith('scripts/ci/');
  const app = paths.some(p => /^(Sources\/|Tests\/|Resources\/|Package\.(swift|resolved)$|version\.txt$)/.test(p));
  const packaging = paths.some(p => /^scripts\/(build\.sh$|package\.py$|test-package\.py$|packaging-requirements\.txt$|icon\.sh$)/.test(p));
  // Workflow changes exercise every check so edits cannot disable their own validation.
  const infrastructure = paths.some(p => workflow(p) || ci(p));
  return {
    app: app || infrastructure,
    package: app || packaging || infrastructure || paths.some(p => p.startsWith('site/fonts/') || /^LICENSE(?:\.|$)/.test(p)),
    release: packaging || infrastructure || paths.some(p =>
      /^(scripts\/(release|homebrew)\/|release-please-config\.json$|\.release-please-manifest\.json$|version\.txt$|Resources\/Info\.plist$|site\/(metadata\.js|release-contract\.js)$)/.test(p)),
    site: infrastructure || paths.some(p => p.startsWith('site/')),
  };
}

export function changedPaths({ event, base, head }) {
  if (!/^[a-f\d]{40}$/.test(base || '') || !/^[a-f\d]{40}$/.test(head || '')) {
    throw new Error('Expected exact base and head commit SHAs');
  }
  // PRs compare the entire branch against its merge base; pushes compare the
  // complete before/after range, not just the last commit. Include both rename paths.
  const range = event === 'pull_request' ? `${base}...${head}` : `${base}..${head}`;
  return execFileSync('git', ['diff', '--name-only', '--no-renames', '-z', range], { encoding: 'utf8' })
    .split('\0').filter(Boolean);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const paths = changedPaths({ event: process.env.EVENT, base: process.env.BASE, head: process.env.HEAD });
  const result = affected(paths);
  appendFileSync(process.env.GITHUB_OUTPUT, Object.entries(result).map(([key, value]) => `${key}=${value}\n`).join(''));
  console.log(JSON.stringify({ paths, affected: result }, null, 2));
}
