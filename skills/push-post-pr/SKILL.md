---
name: push-post-pr
description: 使用者明確要求將目前成果 commit、push 並發布 PR 時使用；先確認完成範圍、PR title 與模板，再核對實際交付結果。
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.0
---

# 發布目前成果為 PR

載入流程不代表已授權 GitHub 寫入；依本次使用者明確要求的範圍執行 commit、push 與 PR，保留既有授權及 repo 規範。

## 執行

1. 先確認所有開發項目均已完成，或使用者已確認略過／不開發；否則停止發布，列出未完成項目。核對實際變更、驗證結果、repo、base 與 head，保留使用者及其他工具的既有變更。
2. 標題與內文用白話繁體中文（zh-TW），技術術語保留原文。Title 使用 conventional commits 格式，例如 `feat(report): 新增報表管理查詢日有效特休匯出`。建立或更新 PR 前必須以 commitlint／config-conventional 實際驗證，失敗先修正，不在 title 未通過時宣稱完成。
3. 讀取 repo 的 PR template 並依格式撰寫；必要時補足處理的問題、執行項目、執行方式、需 Close 的 issue 與後續建議。若 PR 完成 issue 使用 closing keyword；只有相關工作則保留非關閉關聯。
4. 使用 [shell 執行與本文傳遞](references/shell-execution.md) 的環境選擇與 pwsh／bash 分支完成 title 驗證及本文寫入。使用 UTF-8 no BOM 暫存檔與支援的 `--body-file`，讀回確認原文，避免把本文組成 shell 指令。可用工具與 repo 的既有驗證 command 優先；選擇原 command 的 npx 方式時使用參考範例，工具不可用時回報精確缺口。
5. 在已授權範圍內只提交本次變更，確認 commit SHA、push 到正確 feature ref 的結果，再建立或更新同一 PR。依 repo 的 attribution 規範處理 commit，不強制另一個 Git skill。遇到 push 拒絕或未知發布結果，先核對遠端及已建立的 PR，不重複發布或擅自 force-push。
6. 讀回 PR URL／number、base／head／SHA、draft／ready、title／本文及 checks，確認與本次成果相符；保留未完成 checks 與狀態，發布 PR 不代表 checks 已通過。

## 收尾回報

完成、停止或無法繼續時，交代結論／理由、可核對的 repo／PR identity、commit SHA、push 結果、head、實際驗證與未完成 checks。區分 blocking、non-blocking、風險與需要使用者決策的事項；沒有時寫無。分別說明 commit、push、PR、review、merge、branch／worktree 現況，不適用者寫不適用，並提出一個下一步。此流程交付 PR，merge 依另一次明確授權。
