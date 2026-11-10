---
name: finish-and-admin-merge
description: 使用者明確呼叫執行時，一次授權涵蓋本次範圍內的 PR。逐張核實最新 review 與 checks，通過後執行 admin squash merge 並安全收尾。
license: MIT
disable-model-invocation: true
metadata:
  author: sevenflankse
  version: 0.2.0
---

# Admin merge 與工作收尾

本 skill 僅限使用者明確觸發，不依需求內容自動選用。

本 skill 負責 repo／PR 的 merge readiness；依 GitHub 最新狀態判斷，不以任務追蹤器、Manager projection 或前輪敘述代替證據。

## 確認授權範圍與順序

使用者明確呼叫本 skill 執行時，即授權對本次範圍內的一張或多張 PR 執行 admin squash merge。使用者指定的目標優先。未指定時，從當前工作脈絡核對 PR 歸屬，例如本次父 issue 下各子 issue 對應的 PR。若只是討論、引用名稱或要求檢查，維持唯讀。

逐張處理，依使用者指定且符合已知依賴的順序執行。未指定時，先處理前置 PR。確認前置 PR 已合併後，才合併依賴它的 PR。PR 的歸屬、對應或順序有疑義時，只詢問有疑義的部分，暫緩受影響的 PR。已確認的範圍沿用本次授權，無須逐張重問。依工具本身的核准要求執行。Admin merge 可略過第二個帳號的 approve 要求，其餘合併條件依下列流程核實。

## 逐張執行流程

1. 讀取 GitHub 最新狀態，核實 repo、PR URL／number、base、head repo／branch／SHA、PR state、draft、review verdict、未解 blocking／must-fix 與 required checks。Review 必須已完成、對應目前 head，且明確 verdict 為 `Approve` 或 `Clean`（接受小寫 `clean`）。零 finding 或未取得 review 對象時，仍缺少明確 verdict。前一張合併若影響本張的 base 或 head，以合併後的最新狀態判斷 readiness。若本張仍以已合併前置 PR 的 head branch 為 base，核對實際落點。落點不符本次交付目標或無法確認時，暫緩本張並回報 base 問題。
2. PR 為 behind 時，這是本流程的正常責任：同步最新 base、處理可安全解決的衝突、更新同一 PR 的 feature head、重跑並等待 required checks，再核實最新 review 是否仍有效及 PR identity。沿用已有授權，不例行追問；衝突需要產品取捨、checks 失敗、review 失效或 identity 異常時，停在具體決策點。
3. 立即在合併前重核 head 與 readiness，確認 repo 允許後執行 admin squash merge。若平台支援，將合併綁定已核實的 head。head 變動時重新核對 review 與 checks。
4. 讀回 PR 的 merged state 與 merge commit，確認實際結果，再同步 local main／master。保留無關變更；local branch 無法安全 fast-forward 時回報，不用 reset／force 操作掩蓋差異。
5. 盤點本次 branch／worktree 及中間產物。只清理有歸屬證據且可安全移除的本次產物；未 commit 的中間產物也需盤點。不能證明由本 session 產生、或存在他人變更時保留並列給使用者確認；gitignore 本身不是歸屬證據。其他待合併 PR 仍使用的 branch 或 worktree，待依賴解除後再清理。確認結果後才宣稱 cleanup 完成。

## Shell 與工具

使用實際執行 shell 的語法。Git／gh 的普通 CLI 參數可共用；路徑加引號，pwsh 用 `$LASTEXITCODE`，bash 用 `$?` 確認外部命令結果。若需要多行本文，使用原文 UTF-8 no BOM 暫存檔與已確認支援的 `--body-file`，並以對應 shell 的 finally／trap 清理；本文作為資料，不組成可執行命令。依目標 repo 的有效指示處理 commit attribution，無強制 Git skill 依賴。

## 收尾回報

完成、停止或無法繼續時，逐張交代下列資訊，並標明仍待處理的 PR。

- 結論與理由，以及成功／未完成／需要決策的狀態。
- Repo、PR URL／number、base、head branch／SHA、review verdict、blocking／must-fix 數量及處置、checks 與 merge commit；不可確認者標示 unknown。
- 實際執行的驗證與結果；修正後是否有新的 commit／push。
- Blocking、non-blocking、風險與需要使用者取捨的事項，沒有時寫無。
- Commit、push、PR、review、merge、branch 與 worktree cleanup 分別處於何種狀態；不適用者標示不適用。
- 一個根據完整語境的下一步；保留檔案或 cleanup 殘留須列明歸屬與原因。
