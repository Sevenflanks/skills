# skills

Personal agent skills repository for reusable OpenCode / Claude-style skills.

This repository is intended to grow over time. Each skill lives in its own folder under [`skills/`](skills/), with its own `SKILL.md` and optional evaluation files.

## Available skills

### gh-body-file

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

## Repository layout

```text
skills/
└── gh-body-file/
    ├── SKILL.md
    └── evals/
        └── evals.json
```

The `gh-body-file` skill definition is in [`skills/gh-body-file/SKILL.md`](skills/gh-body-file/SKILL.md).

Evaluation prompts are in [`skills/gh-body-file/evals/evals.json`](skills/gh-body-file/evals/evals.json).

## License

MIT. See [`LICENSE`](LICENSE).

## Installation

Copy the skill folder you want into your agent skills directory, or install it with the mechanism your agent runtime provides for GitHub-hosted skills.

For a local OpenCode-style setup, copy `skills/gh-body-file/` so the resulting folder contains at least:

```text
gh-body-file/
├── SKILL.md
└── evals/
    └── evals.json
```
