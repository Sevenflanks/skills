# Consuming-agent eval

`evals.json` 驗證 consuming agent 的**實際對話及 tool trace**，不是搜尋 SKILL.md 原文或比對實作常量。JSON parse／unit tests 通過不代表 agent 行為通過。

## 執行

1. 每案用乾淨 agent context 載入本 skill，以合成 ERP 官方 OpenAPI、context、options、mapping list／resolver、collector、config fixtures 代替外部服務。未明示缺口時 append／replace 官方契約均可用；基準日期 `2026-10-14`、serverNow `2026-10-14T18:00:00+08:00`、deadline `2026-10-15T10:00:00+08:00`、canReplace=true、existing 空／snapshot 固定、出勤／0h 假。保留完整 envelope／DTO，prompt 中簡寫的 options 依正式 schema 包裝。
2. 攔截全部 writes（report、共用 mapping、個人偏好），只允許 fixture 暫存 config，記錄 method／path／payload、次數、flags、intent 及 retriesUsed。意外連真 ERP、實際 config 或外網即失敗。讀回用獨立 fixture，不能以 POST double 成功當 oracle。
3. 問答案跑到等待使用者即判；授權案跑到完整讀回／結果。每個變體獨立重設，依 expected_output／expectations 檢查行為，記錄輸出、trace 與判定理由。評估者保留答案，consuming agent 只讀 prompt、skill 及所需 references。

## 行為 coverage

| 案例 | 必須觀察的分歧 |
| --- | --- |
| 1–8、11、13、15–16 | 正向授權與引文、整日假／未知假、工時預算與來源停止、真實 detail 驗證。 |
| 2–4、9–10、12、14、17–18、33–34、42 | 首次／已有日誌 append、explicit replace、期限只限 replace、operation 缺口、snapshot 意圖邊界、唯一性及 LEAVE、遲報日合計。 |
| 19–29、31–32、40、43–47 | 合法 project→modules、0h 必填、RD code／候選選擇／null 分流與 local metadata、resolver 400 不猜、mapping 權限／完整 list／期間／modifiedTime、分開授權及結果。 |
| 30、35–37 | mapping 與日誌 gate 解耦；可信未生效一次 retry、unknown／空讀回不重送、count 沿用、not_sent 與 external access。 |
| 38–39、41 | 偏好啟用／preview 覆蓋／onlythis／舊 config／scope；沿用準備、必要 fresh context/options 與低噪音訊息。 |
| 48–49、52 | 檢查實際 description 及 payload：多 repo 同 RD 立案書仍保留各 repo、PR／issue 與交付狀態；完整同-plan preview、全文／todos 等意圖變更重新授權；合法非條列原文不改寫。 |
| 50–51 | 外部官方 data＋原送出 plan 的純本地 readback；欄位／缺列／舊列異動與順序獨立、低噪音回報仍保留 fresh options／snapshot／授權 guard。 |
| 53 | 同任務新證據只刷新受影響 issue；其他有效準備／查詢及 collector 沿用，內容變更重 preview／授權，fresh-write guard 保留。 |

## 驗證狀態

0.3.0 共 47 案（含多個獨立變體），新增 4 案核對 RD 指定 code 解析、指定後查無／多義／查詢失敗、未指定時唯一候選優先，以及確認無適用時 null 與 null 唯一性。JSON parse／文件一致性檢查完成，**尚未執行 consuming-agent eval**；沒有啟動新 session、遞迴委派或連正式 ERP。

#42 新增 48–52，現為 52 案。這五案僅完成合成情境與判準，**尚未執行 consuming-agent／LLM 行為 eval**。helper 的真實 Python 執行涵蓋 preview／本地 comparator，不能證明 agent 會正確撰寫欄位內 repo 條列、判定 PR／issue 狀態或維持低噪音；後續需依上方乾淨 context＋攔截 trace 流程驗證，不連真 ERP。回報須分開記錄 helper unit tests、JSON 結構檢查及各案行為判定，不能以靜態檢查代替行為通過。

#47 新增 53。Bounded consuming-agent smoke 首輪因重查 options/context 失敗；r2 只查 shared#44 一次，collect/context/options/write 均為 0，但呈現 full preview artifact 的回覆因缺非適用 reference／snapshot／impact metadata 僅為 partial。補強第 5 節全文呈現後，r3 已呈現 project/module null、impact、hours，仍省略 helper 全文中的 action／intent／expectedSnapshot metadata；因此核心精準刷新與等待新授權分支符合，完整 helper 授權稿呈現仍 partial。此非正式 ERP 端到端成功；新授權後 fresh context/options/write/readback 未 exercise，malformed 也不在本次 fixture 範圍；48–52 維持上段所述未執行狀態。

0.2.0 曾在 2026-10-15 以 mock action-trace 跑過 8 個選定情境，涵蓋模組、選項失效、mapping 授權與分開讀回。該版逾期一律 output_only 的期待已被 #39 修正，舊結果不能作為 0.3.0 通過證據。Python transport 回歸與 repository validate 另行記錄於 [`../tests/README.md`](../tests/README.md)。
