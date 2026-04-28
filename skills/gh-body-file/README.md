# gh-body-file

`gh-body-file` 是一個 GitHub CLI 使用輔助 skill，專門處理 Windows、PowerShell、OpenCode shell 環境中多行 Markdown body 的 quoting 問題。

## 解決的問題

在 Windows／PowerShell／OpenCode shell 中直接把多行 Markdown 傳給 `gh --body` 時，容易遇到引號、換行、特殊字元或編碼問題。此 skill 會要求 agent 改用暫存 `.md` 檔與 `--body-file`，讓 body 傳遞更穩定。

Markdown 若含有反引號，不能先放進 PowerShell 雙引號字串或雙引號 here-string，因為 PowerShell 會解析反引號 escape。即使用暫存檔與 `--body-file`，body 也應由單引號 here-string `@' ... '@` 建立，或來自已保持 literal 的內容；不要先用雙引號字串或雙引號 here-string 組好再寫入暫存檔。若內容可能包含單獨一行 `'@`，也不要嵌入 PowerShell here-string，改用已保持 literal 的外部內容來源。

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

`gh pr comment` 支援 `--body-file`，也可搭配 `--edit-last` 修改目前使用者最後一則 PR comment。若要依 comment ID 修改任意歷史 comment，請改用 `gh api --method PATCH repos/OWNER/REPO/issues/comments/COMMENT_ID`。

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
