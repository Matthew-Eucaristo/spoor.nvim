# Security policy

spoor runs inside your editor on code you open, so any of these is a security issue:

- it writes anywhere other than `stdpath("state")/spoor/` (it must never modify your project or git state);
- it runs any program other than the read-only git commands `rev-parse`, `symbolic-ref`, `merge-base`, `diff --no-ext-diff`, `ls-files`, `grep` and `show <ref>:<path>`;
- it makes a network request or sends code, paths or notes anywhere;
- content in a repository (file names, code, git output) can make it execute code or commands.

## Reporting

Please report privately through GitHub: **Security → Report a vulnerability** on this repository. Do not open a public issue.

Include the spoor version (commit), Neovim version, the language server involved, and steps to reproduce with placeholder paths. You can expect an acknowledgement within a week.

## Supported versions

Only the latest release receives fixes.
