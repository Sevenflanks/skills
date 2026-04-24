# Agent Instructions

本倉庫是 Agent Skills collection。請保持結構一致、變更最小且可驗證。

## 基本規則

- 新 skill 一律放在 `skills/<skill-name>/`。
- 每個 skill 必須有 `SKILL.md`。
- 每個 published skill 必須有 `README.md`。
- `SKILL.md` 必須包含 `name`、`description`、`license`、`metadata.author`、`metadata.version` frontmatter。
- 新增、移除或搬移 skill 時，必須同步更新 `skills.json`、`README.md` 與 `.claude-plugin/marketplace.json`。
- `SKILL.md` 的 `metadata.version` 必須與 `.claude-plugin/marketplace.json` 中對應 entry 的 `version` 一致。
- 若存在 `evals/evals.json`，必須是合法 JSON，且 `skill_name` 必須等於 skill 名稱。
- 不要複製外部 repo 的 skill 內容；只能參考通用架構與維護方式。

## 驗證

完成變更後執行：

```powershell
npm run validate
```

若驗證失敗，先修正根本原因，不要移除檢查來讓 CI 通過。
