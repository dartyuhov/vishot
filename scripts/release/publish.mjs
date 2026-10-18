import { appendFile, readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { GitHub, approve, publish } from './publication.mjs';

const api = new GitHub({ repo: process.env.GH_REPO, token: process.env.GH_TOKEN });
try {
  const approval = await approve(api, {
    sourceSha: process.env.SOURCE_SHA || undefined,
    prNumber: process.env.RELEASE_PR || undefined,
    bot: process.env.RELEASE_APP_BOT_LOGIN,
  });
  if (process.argv[2] === 'prepare') {
    const output = approval ? {
      approved: 'true', source_sha: approval.sha, version: approval.version,
      release_pr: String(approval.prNumber),
    } : { approved: 'false' };
    await appendFile(process.env.GITHUB_OUTPUT,
      Object.entries(output).map(([key, value]) => `${key}=${value}\n`).join(''));
  } else if (process.argv[2] === 'publish') {
    if (!approval) throw new Error('No approved release');
    const directory = process.argv[3];
    if (!directory) throw new Error('Expected package artifact directory');
    const files = new Map();
    for (const entry of await readdir(directory, { recursive: true, withFileTypes: true })) {
      if (!entry.isFile()) {
        if (!entry.isDirectory()) throw new Error('Unexpected artifact file type');
        continue;
      }
      if (files.has(entry.name)) throw new Error(`Duplicate artifact: ${entry.name}`);
      files.set(entry.name, await readFile(join(entry.parentPath, entry.name)));
    }
    console.log(JSON.stringify(await publish(api, approval, files)));
  } else throw new Error('Usage: publish.mjs prepare | publish ARTIFACT_DIRECTORY');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
