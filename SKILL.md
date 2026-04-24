---
name: gh-body-file
description: Use when working in Windows/PowerShell/OpenCode shell with supported `gh` commands that accept `--body-file`, so body content must be written to a temp `.md` file and passed with `--body-file`.
---

## GitHub CLI `--body-file` workaround pattern (Windows / PowerShell / OpenCode shell)

Use this when you are on Windows or OpenCode shell and the target `gh` subcommand supports `--body-file`.

## Scope gate

Before applying this pattern, first confirm the target command supports `--body-file`.

Only apply this pattern to commands that support the flag. The list below is **non-exhaustive** and intentionally includes representative examples, not a complete whitelist.

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
$tmpFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".md")
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$body = @"
Markdown body text goes here
"@

try {
  [System.IO.File]::WriteAllText($tmpFile, $body, $utf8NoBom)
  gh <subcommand> --body-file $tmpFile <other args>
}
finally {
  Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
}
```

## Not an exhaustive rule list

- `--body-file` is not supported by every `gh` subcommand.
- This is a workaround pattern for Windows/PowerShell/OpenCode shell command construction, not the only valid `gh` behavior.
- If a command does not support `--body-file`, prefer the command's normal body transport for that command.

## Required checks (when using the pattern)
- Temporary `.md` path is created.
- `$utf8NoBom = New-Object System.Text.UTF8Encoding($false)` is present before writing.
- Body text is first assigned to a here-string variable.
- Body is written with `[System.IO.File]::WriteAllText($tmpFile, $body, $utf8NoBom)`.
- `gh ... --body-file $tmpFile` is used.
- `Remove-Item` cleanup executes in `finally`.

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
```
