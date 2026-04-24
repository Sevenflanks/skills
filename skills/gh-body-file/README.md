# gh-body-file

`gh-body-file` 是一個 GitHub CLI 使用輔助 skill，專門處理 Windows、PowerShell、OpenCode shell 環境中多行 Markdown body 的 quoting 問題。

## 解決的問題

在 Windows／PowerShell／OpenCode shell 中直接把多行 Markdown 傳給 `gh --body` 時，容易遇到引號、換行、特殊字元或編碼問題。此 skill 會要求 agent 改用暫存 `.md` 檔與 `--body-file`，讓 body 傳遞更穩定。

## 使用時機

當目標 GitHub CLI 子指令支援 `--body-file`，且需要傳入 Markdown body 時使用，例如：

- `gh issue create`
- `gh issue comment`
- `gh issue edit`
- `gh pr create`
- `gh pr comment`
- `gh pr edit`
- `gh pr review`
- `gh pr merge`
- `gh pr revert`

若目標子指令不支援 `--body-file`，不要套用此 workaround。

## 主要流程

1. 建立暫存 `.md` 檔路徑。
2. 建立 UTF-8 no BOM encoding 物件。
3. 將 Markdown body 放入 PowerShell here-string 變數。
4. 使用 `[System.IO.File]::WriteAllText(...)` 寫入暫存檔。
5. 呼叫 `gh <subcommand> --body-file $tmpFile`。
6. 在 `finally` 區塊中用 `Remove-Item` 清理暫存檔。

## 檔案

- [`SKILL.md`](SKILL.md)：skill runtime 指令。
- [`evals/evals.json`](evals/evals.json)：評估案例。
