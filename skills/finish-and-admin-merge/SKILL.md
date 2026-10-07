---
name: finish-and-admin-merge
description: 依最新 PR、review 與 checks 證據執行已授權的 admin squash merge，並安全收尾 branch／worktree。
license: MIT
disable-model-invocation: true
metadata:
  author: sevenflankse
  version: 0.1.1
---

# Admin merge 與工作收尾

本 skill 僅限使用者明確觸發，不依需求內容自動選用。

本 skill 負責 repo／PR 的 merge readiness；依 GitHub 最新狀態判斷，不以任務追蹤器、Manager projection 或前輪敘述代替證據。

## 先確認授權與目標

載入 skill 是取得流程；使用者明確要求 admin merge，才授權對該 PR 合併。這項要求表示不會有第二人／帳號 approve，因此可忽略「必須由第二個帳號 approve」的 gate；其餘 review、blocking finding、checks 與 identity 檢查仍須完成。

先確認目標 repo、PR URL／number、base、head repo／branch／SHA、PR state、draft、review verdict、未解 blocking／must-fix 與 required checks。Review 必須已完成且明確 verdict 為 Approve；沒有 finding 或未成功取得 review 對象不能替代 Approve。無法唯一確認目標時停止並列出缺少的證據。

## 執行流程

1. 以最新 PR state 核實上述資訊，確認沒有未解 blocking／must-fix，並檢查合併前 readiness。
2. PR 為 behind 時，這是本流程的正常責任：同步最新 base、處理可安全解決的衝突、更新同一 PR 的 feature head、重跑並等待 required checks，再核實最新 review 是否仍有效及 PR identity。沿用已有授權，不例行追問；衝突需要產品取捨、checks 失敗、review 失效或 identity 異常時，停在具體決策點。
3. 立即在合併前重核 head 與 readiness，優先使用 admin squash merge；若平台支援，將 merge 寫入綁定已核實的 head。不要在 head 已變動時套用舊 review 或推定成功。
4. 讀回 PR 的 merged state 與 merge commit，確認實際結果，再同步 local main／master。保留無關變更；local branch 無法安全 fast-forward 時回報，不用 reset／force 操作掩蓋差異。
5. 盤點本次 branch／worktree 及中間產物。只清理有歸屬證據且可安全移除的本次產物；未 commit 的中間產物也需盤點。不能證明由本 session 產生、或存在他人變更時保留並列給使用者確認；gitignore 本身不是歸屬證據。只移除本次可清理的 worktree 與不再需要的 feature branch，確認結果後才宣稱 cleanup 完成。

## Shell 與工具

使用實際執行 shell 的語法。Git／gh 的普通 CLI 參數可共用；路徑加引號，pwsh 用 `$LASTEXITCODE`，bash 用 `$?` 確認外部命令結果。若需要多行本文，使用原文 UTF-8 no BOM 暫存檔與已確認支援的 `--body-file`，並以對應 shell 的 finally／trap 清理；本文作為資料，不組成可執行命令。依目標 repo 的有效指示處理 commit attribution，無強制 Git skill 依賴。

## 收尾回報

完成、停止或無法繼續時，依實際脈絡交代：

- 結論與理由，以及成功／未完成／需要決策的狀態。
- Repo、PR URL／number、base、head branch／SHA、review verdict、blocking／must-fix 數量及處置、checks 與 merge commit；不可確認者標示 unknown。
- 實際執行的驗證與結果；修正後是否有新的 commit／push。
- Blocking、non-blocking、風險與需要使用者取捨的事項，沒有時寫無。
- Commit、push、PR、review、merge、branch 與 worktree cleanup 分別處於何種狀態；不適用者標示不適用。
- 一個根據完整語境的下一步；保留檔案或 cleanup 殘留須列明歸屬與原因。
