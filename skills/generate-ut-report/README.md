# generate-ut-report

依時間區間與自然語言條件，產生有來源證據且格式固定的靜態 UT HTML 報告。

## 使用方式

在支援 Agent Skills 的 runtime 呼叫 `generate-ut-report`，並提供本次需求或目標；沒有額外輸入時依入口說明使用前文。安裝時複製整個 skill 資料夾，包含 references 與 evals，不只複製入口。

## 流程與驗證

- [SKILL.md](SKILL.md)：觸發範圍、執行流程與完成條件。
- [evals/evals.json](evals/evals.json)：主要行為與授權邊界的評估情境，使用模擬資料，不操作真實 PR 或正式系統。

## 固定契約與限制

- [HTML Report Contract](references/html-report-contract.md)：八章節、五張 KPI 與靜態 HTML 驗證。
- [Final Response Contract](references/final-response.md)：固定交付欄位。

沿用來源的計數契約；class-summary 的列數與 case 數可能不同，詳見入口的已知限制，不因遷移自行修正。

## 來源與維護

由使用者既有的同名 OpenCode command 遷移，依 Issue #22 調整輸入、外部引用與 shell 相容性。保留來源 command；本 skill 不依賴個人絕對路徑，也未複製外部 repository 的 skill 內容。
