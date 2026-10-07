# finish-and-admin-merge

依最新 PR、review 與 checks 證據執行已授權的 admin squash merge，並安全收尾 branch／worktree。

## 使用方式

本 skill 僅限人工明確觸發：Codex 使用 `$finish-and-admin-merge`，Claude Code 使用 `/finish-and-admin-merge`。其他 runtime 也須由使用者明確指定本 skill。提供本次需求或目標；沒有額外輸入時依入口說明使用前文。

安裝時複製整個 skill 資料夾，包含 [agents/openai.yaml](agents/openai.yaml)、references（如有）與 evals，不只複製入口。

## 流程與驗證

- [SKILL.md](SKILL.md)：觸發範圍、執行流程與完成條件。
- [evals/evals.json](evals/evals.json)：主要行為與授權邊界的評估情境，使用模擬資料，不操作真實 PR 或正式系統。



## 來源與維護

由使用者既有的同名 OpenCode command 遷移，依 Issue #22 調整輸入、外部引用與 shell 相容性。保留來源 command；本 skill 不依賴個人絕對路徑，也未複製外部 repository 的 skill 內容。
