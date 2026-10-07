## HTML Report Contract

所有 `generate-ut-report` 產出的 HTML 必須符合以下固定契約。

### File Naming

- 預設輸出到 `docs/ut-report/`。
- 檔名格式：`ut-report-<scope>-<start>-<end>.html`。
- `scope` 只用小寫英數、dash、underscore；從 normalizedCriteria 推導，例如 `incentive`、`trailerfee`、`all`。
- `start` / `end` 使用原始 `yyyyMMddHHmm`。

### Static HTML Rules

- 必須是單檔靜態 HTML。
- 不放 `<script>`。
- 不放外部 CDN、遠端圖片、外部字型或動態效果。
- CSS 只能內嵌在 `<style>`。
- 可直接用瀏覽器開啟並列印 / 轉 PDF。

### Fixed Section Order

報告章節順序固定如下，不得省略；若無資料，仍保留章節並寫明 `N/A` 或資料限制。

1. Header & Metadata
2. KPI Cards
3. Scope & Criteria
4. Source Summary
5. Test Detail
6. Included Test Files
7. Verification
8. Data Limitations

### Header & Metadata

必須包含：

- 報告標題：`<Scope> UT Report`
- 產生時間：含時區
- 時間區間：起訖時間，含時區
- 使用者原始條件：`rawCriteria`
- 標準化條件：`normalizedCriteria`
- 範圍判定依據：例如 git history、檔案 mtime、測試報告 timestamp
- Detail level：`case-level` 或 `class-summary`

### KPI Cards

固定 5 張，順序與語意如下：

1. `Total`：報告列入的測試項目總數。
2. `Passed`：報告列入且通過的測試項目數。
3. `Excluded`：依條件排除的項目數；不可得時顯示 `N/A`。
4. `Sources`：測試來源數，例如 Maven Surefire、node --test、pytest。
5. `Test Files`：納入測試檔案數。

### Scope & Criteria

固定以清單呈現：

- Time Range
- Module / Scope
- Include Rules
- Exclude Rules
- Scope Evidence

### Source Summary

固定欄位：

| Source | Runner | Command / Report | Test Files | Passed | Excluded | Evidence |
|---|---|---|---:|---:|---:|---|

規則：

- `Source` 用模組或測試來源名稱，例如 `cardif-trailer-fee-bff`。
- `Runner` 用實際 runner，例如 `Maven Surefire`、`node --test`。
- `Command / Report` 放實際命令或報告檔來源。
- `Evidence` 放可驗證摘要，例如 `Tests run: 50, Failures: 0, Errors: 0, Skipped: 0` 或 `tests 7 / pass 7`。

### Test Detail

預設必須產出逐 test case 明細，固定欄位：

| # | Status | Source | Suite | Class / File | Test Case | Duration |
|---:|---|---|---|---|---|---:|

規則：

- `Status` 只使用 `通過`、`N/A`。若使用者要求排除非通過項目，不得列出其他狀態。
- `Duration` 單位需一致；建議 Java/JUnit 使用秒，Node 使用 ms，若混用需在欄位值保留單位。
- 若資料來源無法取得逐 case，只能 class/file summary：
  - Header metadata 的 `Detail level` 必須填 `class-summary`。
  - 仍使用同一張 `Test Detail` 表。
  - `Test Case` 欄填 `N/A`。
  - `Duration` 欄填 `N/A` 或 class-level duration。
  - `Data Limitations` 必須說明為何無法取得逐 case。

### Included Test Files

固定欄位：

| # | Source | File | Selection Reason |
|---:|---|---|---|

`Selection Reason` 需說明為何納入，例如 `git history within range`、`module scope match`、`test report source`。

### Verification

固定列出以下檢查，每項都要有實際值：

- `htmlExists=true`
- `scriptCount=0`
- `countConsistency=pass`
- `sourceTotalsMatch=pass`
- `excludedWords=0`（若使用者要求避免非通過字詞）
- `staticAssets=pass`
- `testCommandsExit=pass` 或 `testCommandsExit=limited`

規則：

- 若使用者未要求避免非通過字詞，`excludedWords` 可填 `N/A`；不要在報告內寫成「使用者未要求排除非通過狀態字詞」，改用中性描述，例如 `本報告未設定額外狀態字詞排除條件`。
- `staticAssets=pass` 代表沒有外部 CDN、遠端圖片、外部字型、外部 stylesheet、外部 script；inline CSS 與 `@media print` 允許。

### Data Limitations

固定章節。若沒有資料限制，寫 `N/A`。

可列事項：

- 測試命令無法執行。
- 只能解析既有報告，未重新執行測試。
- 無法取得排除項目的精確數量。
- 只能取得 class-summary，無法取得逐 case 明細。

## Standard CSS Guidance

報告外觀保持一致：

- 字體：`Microsoft JhengHei`, `Noto Sans TC`, Arial, sans-serif。
- 背景：淡灰或白底。
- KPI cards 使用一致的 `.cards`, `.card`, `.num`, `.label` class。
- 狀態 class 使用 `.status-pass`。
- 表格使用相同 border / padding / header background。
- 列印模式保留 `@media print`。

## Validation Commands

完成報告後必須至少做這些檢查：

- 讀回 HTML 檔案。
- 搜尋 `<script`，結果必須是 0。
- 檢查 KPI total = Source Summary passed 合計 = Test Detail 列入項目數。
- 檢查 `Included Test Files` 筆數 = KPI `Test Files`。
- 若使用者要求排除非通過字詞，搜尋 `失敗|錯誤|略過|skipped|failed|error`，結果必須是 0。
- 檢查固定 8 個章節標題都存在。
- Windows / PowerShell 下驗證 regex 時，pattern 優先用單引號包住，例如 `'(?i)<script'`、`'(?i)(src|href)="https?://'`，避免雙引號與 `\"` 造成 `ParserError`。
