---
name: gh-body-file
description: Use when working in Windows/PowerShell/OpenCode shell with supported `gh` commands that accept `--body-file`, so body content must be written to a temp `.md` file and passed with `--body-file`.
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.1
---

## GitHub CLI `--body-file` workaround pattern (Windows / PowerShell / OpenCode shell)

Use this when you are on Windows or OpenCode shell and the target `gh` subcommand supports `--body-file`.

## Scope gate

Before applying this pattern, first confirm the target command supports `--body-file`.

Only apply this pattern to commands that support the flag. The list below is **non-exhaustive** and intentionally includes representative examples, not a complete whitelist.

## PowerShell backtick safety rule

PowerShell double-quoted strings and double-quoted here-strings interpret backtick escapes before `gh` receives the body. Markdown sequences like `` `a ``, `` `f ``, and `` `r `` can become alert, form-feed, or carriage-return characters and corrupt GitHub comment bodies.

For Markdown body variables created inside PowerShell, use a single-quoted here-string: `@' ... '@`. Do not use double-quoted strings or `@" ... "@` for Markdown bodies that may contain backticks. Only use a here-string when the body is known not to contain a standalone closing marker line (`'@`); otherwise use already-literal external file/source content instead of embedding arbitrary Markdown in PowerShell source.

## Known supported-command examples
- `gh issue create`
- `gh issue comment`
- `gh issue edit`
- `gh pr create`
- `gh pr comment`
- `gh pr edit`
- `gh pr review`
- `gh pr merge`
- `gh pr revert`

If a command does not accept `--body-file` (for example, when docs/help do not list the flag), do not use this pattern.

## Recommended PowerShell workaround sequence
When in scope, use this safe flow pattern:

```powershell
$tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) (([System.IO.Path]::GetRandomFileName()) + ".md")
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$body = @'
Markdown body text goes here
'@

try {
  [System.IO.File]::WriteAllText($tmpFile, $body, $utf8NoBom)
  gh <subcommand> --body-file $tmpFile <other args>
}
finally {
  Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
}
```

## Not an exhaustive rule list

- `--body-file` is not supported by every `gh` subcommand.
- This is a workaround pattern for Windows/PowerShell/OpenCode shell command construction, not the only valid `gh` behavior.
- If a command does not support `--body-file`, prefer the command's normal body transport for that command.

## PR comment command boundaries

Supported `gh pr comment` forms:

```powershell
gh pr comment PR_NUMBER --body-file $tmpFile
gh pr comment PR_NUMBER --edit-last --body-file $tmpFile
```

- `gh pr comment PR_NUMBER --body-file $tmpFile` is supported for new PR comments.
- `gh pr comment PR_NUMBER --edit-last --body-file $tmpFile` is supported only for editing the current user's last PR comment.
- Do not represent arbitrary historical comment edits as `gh pr comment --edit <comment-id>`. That command form is not supported.

For arbitrary issue or PR comment ID edits, use the REST issue comments endpoint through `gh api`:

Before PATCHing an arbitrary `COMMENT_ID`, verify the target repository and comment identity, for example by fetching the comment first or using a known GitHub URL/ID.

```powershell
gh api --method PATCH repos/OWNER/REPO/issues/comments/COMMENT_ID -F "body=@$tmpFile"
```

JSON payload-file alternative:

```powershell
$payloadFile = Join-Path ([System.IO.Path]::GetTempPath()) (([System.IO.Path]::GetRandomFileName()) + ".json")
$payload = @{ body = $body } | ConvertTo-Json -Depth 10

try {
  [System.IO.File]::WriteAllText($payloadFile, $payload, $utf8NoBom)
  gh api --method PATCH repos/OWNER/REPO/issues/comments/COMMENT_ID --input $payloadFile
}
finally {
  Remove-Item -LiteralPath $payloadFile -ErrorAction SilentlyContinue
}
```

## Required checks (when using the pattern)
- Temporary `.md` path is generated directly under the temp directory; do not create one temp file and then switch to a different extension/path.
- `$utf8NoBom = New-Object System.Text.UTF8Encoding($false)` is present before writing.
- Markdown body text created inside PowerShell is first assigned to a single-quoted here-string variable with `@' ... '@`.
- Here-string body text is known not to contain a standalone closing marker line (`'@`); otherwise the body comes from an already-literal file/source.
- Body is written with `[System.IO.File]::WriteAllText($tmpFile, $body, $utf8NoBom)`.
- `gh ... --body-file $tmpFile` is used.
- `Remove-Item -LiteralPath` cleanup executes in `finally`.

## Allowed examples
```powershell
gh issue create --title "Bug" --body-file $tmpFile
gh issue comment 123 --body-file $tmpFile
gh issue edit 123 --body-file $tmpFile
gh pr create --title "Bug" --body-file $tmpFile
gh pr comment 123 --body-file $tmpFile
gh pr edit 123 --body-file $tmpFile
gh pr review 123 --approve --body-file $tmpFile
gh pr merge 123 --auto --body-file $tmpFile
gh pr revert 123 --body-file $tmpFile
gh pr comment 123 --edit-last --body-file $tmpFile
# After verifying the target repository and comment identity:
gh api --method PATCH repos/OWNER/REPO/issues/comments/456 -F "body=@$tmpFile"
```

## Common mistakes

| Mistake | Correct pattern |
| --- | --- |
| Using `$body = @" ... "@` for Markdown with backticks | Use `$body = @' ... '@` so PowerShell does not interpret backtick escapes. |
| Embedding arbitrary Markdown that may contain a standalone `'@` line | Use an already-literal external file/source instead of a PowerShell here-string. |
| Rejecting `gh pr comment PR_NUMBER --body-file $tmpFile` | Use it for new PR comments because `gh pr comment` supports `--body-file`. |
| Using `gh pr comment --edit <comment-id>` for old comments | Use `gh api --method PATCH repos/OWNER/REPO/issues/comments/COMMENT_ID`. |
| Treating `--edit-last` as arbitrary comment editing | Use `--edit-last` only for the current user's last PR comment. |
