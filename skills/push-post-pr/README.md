# push-post-pr

確認工作完成後，依授權 commit／push 並發布繁中 PR，核對 title、本文與交付狀態。

## 使用方式

在支援 Agent Skills 的 runtime 呼叫 `push-post-pr`，並提供本次需求或目標；沒有額外輸入時依入口說明使用前文。安裝時複製整個 skill 資料夾，包含 references 與 evals，不只複製入口。

## 流程與驗證

- [SKILL.md](SKILL.md)：觸發範圍、執行流程與完成條件。
- [evals/evals.json](evals/evals.json)：主要行為與授權邊界的評估情境，使用模擬資料，不操作真實 PR 或正式系統。

## Shell 分支

[Shell 執行與本文傳遞](references/shell-execution.md) 提供 pwsh／bash 的 title 驗證、原文本文與清理範例。Git／GitHub CLI／commitlint 的可用性依執行環境偵測；不指定個人安裝路徑。

## 來源與維護

由使用者既有的同名 OpenCode command 遷移，依 Issue #22 調整輸入、外部引用與 shell 相容性。保留來源 command；本 skill 不依賴個人絕對路徑，也未複製外部 repository 的 skill 內容。
