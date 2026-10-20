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

## 驗證狀態

0.3.0 共 47 案（含多個獨立變體），新增 4 案核對 RD 指定 code 解析、指定後查無／多義／查詢失敗、未指定時唯一候選優先，以及確認無適用時 null 與 null 唯一性。JSON parse／文件一致性檢查完成，**尚未執行 consuming-agent eval**；沒有啟動新 session、遞迴委派或連正式 ERP。

0.2.0 曾在 2026-10-15 以 mock action-trace 跑過 8 個選定情境，涵蓋模組、選項失效、mapping 授權與分開讀回。該版逾期一律 output_only 的期待已被 #39 修正，舊結果不能作為 0.3.0 通過證據。Python transport 回歸與 repository validate 另行記錄於 [`../tests/README.md`](../tests/README.md)。
