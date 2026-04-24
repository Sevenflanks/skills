# gh-body-file

Agent skill for safely using GitHub CLI commands that support `--body-file` from Windows, PowerShell, and OpenCode shell sessions.

The skill guides agents to write Markdown bodies to a temporary `.md` file with UTF-8 no BOM encoding, pass that file to supported `gh` commands, and clean up the temporary file in a `finally` block.

## When to use

Use this skill when working with supported GitHub CLI commands that accept `--body-file`, especially when command-line quoting or multiline Markdown bodies are fragile in Windows or OpenCode shell environments.

Representative supported commands include:

- `gh issue create`
- `gh issue comment`
- `gh issue edit`
- `gh pr create`
- `gh pr comment`
- `gh pr edit`
- `gh pr review`
- `gh pr merge`
- `gh pr revert`

Always confirm the target `gh` subcommand supports `--body-file` before applying the workaround.

## Skill file

The skill definition is in [`SKILL.md`](SKILL.md).

Evaluation prompts are in [`evals/evals.json`](evals/evals.json).

## License

MIT. See [`LICENSE`](LICENSE).

## Installation

Copy this repository's skill folder into your agent skills directory, or install it with the mechanism your agent runtime provides for GitHub-hosted skills.

For a local OpenCode-style setup, the resulting folder should contain at least:

```text
gh-body-file/
├── SKILL.md
└── evals/
    └── evals.json
```
