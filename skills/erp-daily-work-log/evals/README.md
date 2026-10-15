# Consuming-agent eval

`evals.json` 是 agent 情境，不是搜尋 SKILL.md 文字的 unit test。每案以乾淨 agent context、載入本 skill，使用合成的唯讀 ERP／collector／scoped write doubles；不要連真 ERP。以 `prompt` 提供輸入，依 `expected_output` 與 `expectations` 判定**實際對話及 tool trace**。

1. mock 官方 OpenAPI、context、options、mapping list／resolver 及 collector。未明示錯誤的未逾期基準用 reportDate `2026-10-14`、serverNow `2026-10-14T18:00:00+08:00`、deadline `2026-10-15T10:00:00+08:00`、canReplace=true、existing空／snapshot固定、出勤／0h假；保留官方 envelope 與完整 DTO。prompt 中的 id／label 清單是語意 fixture，依當次正式 schema 包裝，不讓 agent 發明欄位。
2. 只回傳該情境允許的資料；攔截全部 writes，記錄 method/path/payload/次數及兩個 helper flags。凡意外連外一律失敗。report 與 mapping 的 readback 也記錄，不能用 POST double 的成功當 oracle。
3. 問答案執行到 agent 等待使用者即判；已授權案跑到 readback／結果。每個「變體」獨立重設 session/fixtures；記實際輸出、trace、pass/fail與理由，不把 JSON結構通過當 consuming-agent 通過。

## 新增 coverage（19–32）

| 案例 | 必須觀察的分歧 |
| --- | --- |
| 19–23 | singleton、不同 topics 多模組、唯一名稱證據、多義／未知候選詢問、0h必填、非法project空list與合法無modules。 |
| 24–27 | 只本次不存、預設日期與差異、獨立save授權、完整list/resolver讀回、無維護權限／缺API／拒存仍可report。 |
| 28–29 | PUT不改projectId、原timestamp精度、重疊/stale/timeout不自動重試或改期。 |
| 30–32 | 逾期所有mapping/module操作為零、fullleave零collect、mapping/report獨立結果、寫前選項失效重問。 |

## 本輪選定情境結果（2026-10-15）

主 agent 以 fresh consuming-agent contexts 載入實際 skill／reference，提供合成 ERP／collector fixtures；consuming agent 未讀本檔、`evals.json` 的期待或測試答案。業務 operations 以受控 action trace 代替，未執行 helper、連網或寫入 ERP；由主 agent 依既有 expectations 另行判定。

| 對應情境 | 實際觀察／判定 |
| --- | --- |
| 20：同 repo 兩主題 | 依發票對帳／出勤證據選 71／72，預覽列理由與提議 4h／4h，未選第一筆「其他」，未寫入。符合。 |
| 21–22：未知模組、要求 0h／null | 列合法候選詢問，未以 0h 或直接提交繞過模組條件。符合。 |
| 32：寫前模組失效 | snapshot 相同，重新查 project／module 後辨識 71 已失效，詢問 72／73，不默換、不提交。符合。 |
| 24：只供本次、不存 mapping | 保留合法手選 project 7／module 71，完成 dry-run、單次模擬 report write 及獨立完整讀回；mapping write 為零。符合。 |
| 25：尚未同意永久存 | 預覽新增日期 `reportDate..null`、repo／可靠 branch／project，日誌與永久儲存分開詢問，沒有 POST／PUT。符合。 |
| 30：逾期且未知工時／branch | 先分流 output_only，再 probe→預告→collect；mapping／module queries、所有 writes、未知欄位問答皆為零。符合。 |
| 26／31：mapping 已存、report timeout | mapping 單次模擬 POST 後以完整 list＋resolver 核對；report timeout 後獨立查回，分別報成功與不確定，不重試或刪 mapping 回滾。符合。 |
| 27：無維護權仍可回報 | 維護 projects 空時只停用 save，保留合法 report project／module，單次模擬 report write 與完整讀回；mapping write 為零。符合。 |

共 **8 個有效合成情境**符合觀察條件。初次「模組失效」fixture 的 prior／fresh snapshot 字串意外不同，未計入結果；修正為逐字相同後，以新 context 重跑，確認不是靠 snapshot 衝突而停止。

這是選定情境的 consuming-agent／mock action-trace 評估，**不是完整 32 案及所有變體的自動 evalrunner，也不代表真實 ERP、helper transport 或部署驗證**。Python transport regression 與 `npm validate` 是另外的驗證證據，不互相替代。
