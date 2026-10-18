import { pathToFileURL } from 'node:url';
import { GitHub, Manifest } from 'release-please';

// 17.11.2 exclude-paths matches directory prefixes only, not files or globs.
// Remove documentation paths at the SCM boundary so the existing all-files
// exclusion applies, including deleted/new files. Keep SHAs and messages intact
// for bootstrap/release boundaries, and keep genuine files in mixed commits.
export async function releaseManifest(scm, targetBranch = 'main', options = {}) {
  const classified = new Proxy(scm, {
    get(target, key) {
      if (key === 'mergeCommitIterator') return async function* (...args) {
        for await (const commit of target.mergeCommitIterator(...args)) {
          yield { ...commit, files: commit.files?.filter(file => !/\.(md|markdown|mdown|mkd|mdx)$/i.test(file)) };
        }
      };
      const value = Reflect.get(target, key);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  return Manifest.fromManifest(classified, targetBranch, undefined, undefined, options);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [owner, repo, extra] = (process.env.GH_REPO || '').split('/');
  if (!owner || !repo || extra || !process.env.GH_TOKEN) throw new Error('GH_REPO and GH_TOKEN are required');
  const scm = await GitHub.create({ owner, repo, token: process.env.GH_TOKEN });
  await (await releaseManifest(scm)).createPullRequests();
}
