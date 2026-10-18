// Match the herdr-blink title convention. Titles are passed as data, never shell code.
const title = process.argv[2] ?? process.env.PR_TITLE ?? '';
const pattern = /^(feat|fix|docs|chore|refactor|perf|test|build|ci|revert)(\([a-zA-Z0-9_./-]+\))?!?: \S[^\r\n]*$/;
if (title !== title.trim() || !pattern.test(title)) {
  console.error('Use a Conventional Commit title, such as fix: correct capture or feat(capture)!: change selection behavior');
  process.exitCode = 1;
}
