# to-spec-or-ticket

判斷需求應產生 spec 或 tickets，載入選中流程；不適合時僅提出下一步建議。

## 使用方式

本 skill 僅限人工明確觸發：Codex 使用 `$to-spec-or-ticket`，Claude Code 使用 `/to-spec-or-ticket`。其他 runtime 也須由使用者明確指定本 skill。提供本次需求或目標；沒有額外輸入時依入口說明使用前文。

安裝時複製整個 skill 資料夾，包含 [agents/openai.yaml](agents/openai.yaml)、references（如有）與 evals，不只複製入口。

## 流程與驗證

- [SKILL.md](SKILL.md)：觸發範圍、執行流程與完成條件。
- [evals/evals.json](evals/evals.json)：主要行為與授權邊界的評估情境，使用模擬資料，不操作真實 PR 或正式系統。

## 外部依賴

`to-spec` 與 `to-tickets` 依路由條件擇一載入；需具備本次選中的流程。名稱、原文與核准點由外部安裝提供，此 repo 不包含其內容。Tracker 使用目標專案配置，不指定這個 skills repo 當通用目標。

## 來源與維護

由使用者既有的同名 OpenCode command 遷移，依 Issue #22 調整輸入、外部引用與 shell 相容性。保留來源 command；本 skill 不依賴個人絕對路徑，也未複製外部 repository 的 skill 內容。
