import { GitHub, recoverPublishedLabels } from './publication.mjs';

try {
  const api = new GitHub({ repo: process.env.GH_REPO, token: process.env.GH_TOKEN });
  const readOnly = process.argv.includes('--check');
  const prs = await recoverPublishedLabels(api, { bot: process.env.RELEASE_APP_BOT_LOGIN, readOnly });
  console.log(JSON.stringify({ readOnly, releasePRs: prs }));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
