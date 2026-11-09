# to-spec-or-ticket

依需求直接拆票、先發布 spec 再接續拆票，或提出下一步建議。

## 使用方式

本 skill 僅限人工明確觸發：Codex 使用 `$to-spec-or-ticket`，Claude Code 使用 `/to-spec-or-ticket`。其他 runtime 也須由使用者明確指定本 skill。提供本次需求或目標；沒有額外輸入時依入口說明使用前文。

安裝時複製整個 skill 資料夾，包含 [agents/openai.yaml](agents/openai.yaml)、references（如有）與 evals，不只複製入口。

## 流程與驗證

- [SKILL.md](SKILL.md)：觸發範圍、執行流程與完成條件。
- [evals/evals.json](evals/evals.json)：主要行為與授權邊界的評估情境，使用模擬資料，不操作真實 PR 或正式系統。

## 外部依賴

路由前若有需要使用者回答的問題，使用 `grill-with-docs` 釐清。直接拆票需安裝 `to-tickets`。先寫規格的路徑需要 `to-spec` 和 `to-tickets`，規格發布成功後會在同一個 session 自動接續拆票。發布規格前仍須確認測試 seam，發布票券前仍須確認拆票粒度與 blocking edges。Tracker 使用目標專案的配置。

## 來源與維護

由使用者既有的同名 OpenCode command 遷移，依 Issue #22 調整輸入、外部引用與 shell 相容性。保留來源 command；本 skill 不依賴個人絕對路徑，也未複製外部 repository 的 skill 內容。
