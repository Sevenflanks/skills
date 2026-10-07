---
name: start-from-matt
description: 開始正式任務前，需要根據本次需求或前文判斷適合的 Matt skill／流程時使用；建議流程並直接開始可做的分析。
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.0
---

# 從 Matt 流程開始

1. 取得使用者本次需求；只有 skill 名稱而沒有需求時，使用前文已提出的需求，不另猜新任務。
2. 分析需求及已知 repo 現況，確認外部 `ask-matt` 可載入，讀取其原文後判斷適合工序。依 runtime 的 skill 目錄或載入機制定位，不硬編碼個人路徑，不複製外部 skill。
3. 列出建議工序、理由與下一步。唯讀／分析工序立即開始；若建議直接 `tdd`／`implement`，在該階段交由使用者決定，不因路由自動開始實作。
4. 後續真正改檔的工作使用 worktree，確認目標 repo／基線，保留既有變更；commit／push／PR／merge 仍依當次授權。

`ask-matt` 是必要外部依賴。找不到、名稱不唯一或不能載入時，回報具體缺口與 runtime 可用的安裝／指定來源方式，保留已完成分析；不自行拼造 Matt 流程或宣稱已執行。此 skill 不修改外部設定或自動安裝依賴。

回覆使用者：需求摘要、選擇工序、已完成分析、需要使用者決定的階段，以及任何依賴缺口。操作工具依實際 pwsh／bash 環境，不以作業系統推定 shell。
