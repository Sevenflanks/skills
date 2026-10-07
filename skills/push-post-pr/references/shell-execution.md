# Shell 執行與本文傳遞

驗證 title 或傳送多行 PR 本文前讀取。以工具實際執行的 shell 為準：Windows 也可能使用 Git Bash／WSL，pwsh 也可能在非 Windows 上執行。確認 Git、gh、Node／npm／npx 或 repo 既有 title validator 的可用性；普通 CLI 參數可共用，字串、路徑、清理與 exit code 使用選中的分支。

下面範例的 `repo`、`base`、`branch`、`title` 是已確認目標的資料。僅在發布已獲授權時執行 gh 寫入；測試範例應替換成 mock，不操作真實 PR。若工具 command 不支援 `--body-file`，改用其正式本文介面，不假設所有 gh 子指令都支援。

## Title 驗證

優先沿用已配置的 conventional commit validator；原 command 的 npx 方式如下。使用傳給 PR 的同一 title，驗證後檢查 exit code；失敗先修正。以下各段須在相應 shell 執行，不能混用。npx 是本次 CLI 執行，不需加入 production dependency。

### pwsh

```powershell
$title | npx --yes -p @commitlint/cli -p @commitlint/config-conventional commitlint --extends @commitlint/config-conventional
$lintExit = $LASTEXITCODE
if ($lintExit -ne 0) { throw "PR title 驗證失敗，exit=$lintExit" }
```

pwsh 7 的 UTF-8 管線可傳遞中文；使用非預設編碼環境時，確認送給 native command 的 encoding，並保留原設定。Windows 若存在 executable 同名腳本而受到執行原則限制，可用已確認位置的 `npx.cmd`；不改變全域執行原則。

### bash

```bash
(
  set -o pipefail
  printf '%s\n' "$title" | npx --yes -p @commitlint/cli -p @commitlint/config-conventional commitlint --extends @commitlint/config-conventional
  lint_exit=$?
  exit "$lint_exit"
)
```

呼叫端先核對本段的 exit code，再進入發布；非零時停止。Subshell 中的 pipefail 不改變呼叫端設定。

## 原文本文與暫存檔

兩段範例共用同一段示範 Markdown，保留中文、引號、反引號、`$()` 與換行；不得對本文使用 eval 或 Invoke-Expression。正式內容可由可用的檔案寫入工具產生。任意正文可能包含 here-string／heredoc 的結束標記時，使用已存在的原文檔案或選擇確認不出現的標記，不直接把未檢查的正文嵌入腳本。

### pwsh

```powershell
$bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) (([System.IO.Path]::GetRandomFileName()) + '.md')
$body = @'
## 測試正文
保留 `code`、$()、"引號" 與中文。
第二行：原文不展開。
'@
try {
    [System.IO.File]::WriteAllText($bodyFile, $body, [System.Text.UTF8Encoding]::new($false))
    if ([System.IO.File]::ReadAllText($bodyFile) -cne $body) { throw 'PR 本文讀回與原文不同。' }
    gh pr create --repo $repo --base $base --head $branch --title $title --body-file $bodyFile
    $publishExit = $LASTEXITCODE
    if ($publishExit -ne 0) { throw "PR 發布失敗，exit=$publishExit；先讀回確認再重試。" }
}
finally {
    Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
}
```

### bash

```bash
(
  body_dir=$(mktemp -d "${TMPDIR:-/tmp}/pr-body.XXXXXX") || exit "$?"
  body_file="$body_dir/body.md"
  trap 'rm -f -- "$body_file"; rmdir -- "$body_dir"' EXIT
  body=$(cat <<'PR_BODY_LITERAL'
## 測試正文
保留 `code`、$()、"引號" 與中文。
第二行：原文不展開。
PR_BODY_LITERAL
  )
  body_exit=$?
  [ "$body_exit" -eq 0 ] || exit "$body_exit"
  printf '%s\n' "$body" > "$body_file"
  write_exit=$?
  [ "$write_exit" -eq 0 ] || exit "$write_exit"
  read_body=$(cat -- "$body_file")
  read_exit=$?
  [ "$read_exit" -eq 0 ] || exit "$read_exit"
  if [ "$read_body" != "$body" ]; then
    printf '%s\n' 'PR 本文讀回與原文不同。' >&2
    exit 1
  fi
  gh pr create --repo "$repo" --base "$base" --head "$branch" --title "$title" --body-file "$body_file"
  publish_exit=$?
  exit "$publish_exit"
)
```

Bash 原文檔案的來源使用 UTF-8 no BOM。temp directory／檔案均屬於本次呼叫，只清理這些已知路徑，不做遞迴刪除。呼叫端保存 exit code 後才執行其他 command；非零時先讀回遠端確認是否已產生 PR，不盲目重試。

## 路徑與結果

pwsh 的 native arguments 與 bash 的空白切詞規則不同；路徑傳遞保持單一 argument，bash 變數加雙引號，pwsh 的檔案操作使用 LiteralPath。Git Bash／WSL 與原生 Windows executable 共用時確認工具期望的路徑格式，只在必要時做可用的 path conversion。不要把 JSON 字串化視為 shell quoting。

遇到 stderr／非零 exit code，保留原錯誤與對應目標；清理成功不能取代發布成功。範例驗證的環境及未驗證平台由本次交付證據記錄，不能將 Git Bash 的結果宣稱為所有 Unix 平台皆已測試。
