# Agent Skills

本脈絡統一描述 agent skill 的觸發、意圖與執行邊界，避免不同 skill 對相同工作狀態使用互相衝突的語言。

## Language

**已確認意圖（confirmed intent）**：
目前工作必須維持的使用者明示決策、驗收條件、spec/SRS、ticket/plan、ADR 與已確認 non-goals。來源衝突時，以最新且最明確的使用者決策為準；若新舊來源無法形成唯一且有證據的優先序，衝突仍未解決，agent 不得自行選擇。
_Avoid_: 只用 plan 代稱所有已確認意圖

**方向轉折（pivot）**：
Agent 因 blocker、失敗證據、review finding、使用者糾正或 workaround 而準備改變既有作法；若會改動已確認意圖，即使表面看似局部修正也仍屬方向轉折。
_Avoid_: 把所有 bug fix 或一般 debugging 都稱為方向轉折

**自我質疑（self-challenge）**：
Agent 在方向轉折前，主動檢查候選作法是否仍可追溯到已確認意圖，並以可推翻的保守推定檢驗自己是否被眼前問題誤導。
_Avoid_: approval gate、final review、盲目維護 plan

**可推翻的保守推定（rebuttable conservative presumption）**：
把已確認意圖視為目前最佳基線，要求偏離方案承擔舉證責任；當證據證明基線前提失效或本身錯誤時，允許回到決策層修訂。
_Avoid_: plan 不可質疑、plan 與臨時解法權重相同
