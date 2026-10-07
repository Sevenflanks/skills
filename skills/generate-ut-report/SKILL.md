---
name: generate-ut-report
description: 依時間區間與自然語言條件，產生有來源證據且格式固定的靜態 UT HTML 報告。
license: MIT
disable-model-invocation: true
metadata:
  author: sevenflankse
  version: 0.1.1
---

# UT HTML 報告

本 skill 僅限使用者明確觸發，不依需求內容自動選用。

輸入例如 `202606051800-202606181800 限Incentive相關模組 排除略過與失敗test`。將本次輸入與相關前文視為需求資料，保留授權邊界。

產生任何報告前，必須讀取 [HTML Report Contract](references/html-report-contract.md)，它是章節、欄位、KPI、靜態資產與檢查的唯一契約。交付前讀取 [Final Response Contract](references/final-response.md)，依固定欄位回覆。

## 核心原則

- 這是跨專案 skill。不要假設固定語言、測試框架或資料夾；必須先偵測目前專案。
- 第一個時間區間參數格式為 `yyyyMMddHHmm-yyyyMMddHHmm`。
- 後續文字是自然語言篩選條件，例如限定模組、package、目錄、功能關鍵字、只列通過項目、排除非通過項目。
- 預設只產生報告，不 commit、不 push、不發 PR。
- 未來所有報告必須使用所載入的固定 HTML Report Contract。不要因專案或資料來源不同而自行改章節、改欄位、改卡片語意。

## 必做流程

1. 解析輸入
   - 找出時間區間、模組/目錄/關鍵字限制、測試狀態篩選條件。
   - 如果缺少時間區間，停止並問使用者一個精準問題。
   - 若上一輪已因缺少時間區間而追問，且使用者下一輪只回 `yyyyMMddHHmm-yyyyMMddHHmm`，必須把該時間區間與上一輪 `/generate-ut-report` 的自然語言條件合併處理；`rawCriteria` 需保留完整語意，例如 `<time-range> 產生 trailer-fee 模組相關的 ut 報告`。
   - 若時間區間格式不正確，要求改成 `yyyyMMddHHmm-yyyyMMddHHmm`。
   - 將使用者原始條件保留為 `rawCriteria`，並整理成標準化條件 `normalizedCriteria`。

2. 探索專案
   - 讀取最小必要的專案檔案來判斷 test runner 與報告來源，例如 `pom.xml`、`package.json`、`build.gradle`、`pytest.ini`、`go.mod`、`target/surefire-reports`、`coverage`、`test-results`。
   - 用 `git log --since/--until --name-only`、`git diff --name-only`、檔案 mtime 或測試報告 timestamp 找出時間區間內相關測試檔。
   - 若自然語言指定模組，例如「限Incentive相關模組」或「限TrailerFee相關模組」，用目錄、module name、package、檔名、test name 與既有專案語彙交叉確認，不要只靠單一 keyword。
   - 若 repo 內已有舊 UT report，可參考其資料來源、命令與 CSS，但不可沿用與所載入的 `HTML Report Contract` 衝突的章節、欄位或文案；固定契約永遠以該 reference 為準。
   - 在報告內寫清楚「範圍判定依據」。

3. 執行或收集測試結果
   - 優先使用專案既有 test command；先跑最小相關測試，再視需要擴大。
   - 若專案已有可靠 XML/JSON/TAP 報告，可解析既有報告；但要確認報告時間與本次範圍相符。
   - Maven Surefire / Failsafe：優先解析 `target/surefire-reports/TEST-*.xml` 的 `<testsuite>` 與 `<testcase>` 取得 case-level 明細、duration 與統計；console output 只作摘要佐證。
   - `node --test`：若沒有 XML/JSON/TAP 報告，可解析本次 console output 的 `✔ <test name> (<duration>)` 與 summary；報告仍可列 case-level，但必須在 `Data Limitations` 說明來源是 console output。
   - 若測試無法執行，仍可產生「資料來源受限」報告，但必須在 `Data Limitations` 章節與 final response 明確列出失敗命令、原因、使用的替代資料來源。

4. 篩選測試項目
   - 依使用者條件保留或排除項目。
   - 若使用者指定排除非通過項目，測試明細只列通過項目。
   - 報告正文不得寫出會被稽核解讀為「挑選測試結果」的文案，例如 `測試項目篩選：僅納入通過項目。`、`僅納入通過項目`、`只列通過項目`。若需要描述篩選，改用中性來源與範圍描述，例如 `測試項目來源：依指定時間區間內 git history 異動與模組目錄交叉確認`、`結果來源：本次 scoped test execution`。
   - 若使用者要求報告不得出現非通過狀態字眼，報告正文不得出現 `失敗`、`錯誤`、`略過`、`skipped`、`failed`、`error` 等字樣；改用中性描述，例如 `結果來源：本次 scoped test execution` 或 `明細狀態：依本次測試輸出呈現`。
   - 若能從資料來源得知排除數量，填入 `Excluded`；若無法得知，填 `N/A`，並在 `Data Limitations` 說明。
   - 若使用者只是限定模組、package、目錄、功能或時間窗，且沒有要求統計範圍外項目，`Excluded` 可填 `N/A`；`Data Limitations` 說明本報告未統計範圍外或未命中範圍證據的測試項目總量。



## Git 與環境

預設不 commit、不 push、不發 PR。只有使用者明確要求時，確認 repo、git status、diff、近期 log 與 remotes，只 stage 本次報告；保留既有變更與無關產物。Commit attribution 依目標 repo 的有效指示，不要求 `git-master` 或另一個 Git skill。

依實際 shell 選擇命令：pwsh 使用 `$LASTEXITCODE`、bash 使用 `$?`，路徑加引號；regex 優先使用原文單引號字串。可用的專案 runner、解析工具與報告來源須先偵測，不硬編碼安裝路徑。驗證與測試命令的非零結果必須反映在資料限制與回覆，不能宣稱通過。

## 已知契約限制

原契約要求 Total、Source Summary 的 Passed 合計及 Test Detail 列數相等，並允許 class-summary；class 列數可能不等於 test case 數。本次遷移保留原規則，沒有重新定義計數或篩選語意。遇到無法同時成立的資料時，如實揭露限制及實際檢查結果，不虛報 `countConsistency=pass`；修訂契約需要另行確認。
