# 貢獻指南

感謝你想改善這個 skills 倉庫。此 repo 的目標是維持可發現、可驗證、可長期維護的 Agent Skills collection。

## 新增 skill

1. 在 `skills/<skill-name>/` 建立新資料夾。
2. 新增必要檔案：`skills/<skill-name>/SKILL.md`。
3. 新增必要文件：`skills/<skill-name>/README.md`。
4. 若 skill 有可驗證行為，加入 `skills/<skill-name>/evals/evals.json`。
5. 更新 `skills.json`，加入 skill 的名稱、路徑、摘要、版本、授權、作者、標籤與狀態。
6. 更新 `.claude-plugin/marketplace.json`，同步版本與描述。
7. 更新 `README.md` 的「目前收錄的 skills」表格。
8. 執行 `npm run validate`，確認驗證通過。

## SKILL.md 基本要求

`SKILL.md` 必須包含 YAML frontmatter：

```yaml
---
name: your-skill-name
description: 清楚描述何時應觸發此 skill，以及它能協助完成什麼任務。
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.0
---
```

撰寫 skill 時請保持：

- 指令具體、可操作。
- 說明何時使用與何時不要使用。
- 若流程涉及工具或命令，寫出必要的安全檢查。
- 避免放入秘密、憑證、私有系統細節或與 skill 無關的內容。

## 評估案例

若新增 `evals/evals.json`，請至少包含：

- `skill_name`
- `evals` 陣列
- 每個 eval 的 `prompt` 與 `expected_output`

可從 [`templates/evals.template.json`](templates/evals.template.json) 開始。

## 提交前檢查

提交前請執行：

```powershell
npm run validate
```

並確認：

- `git status` 只包含本次變更需要的檔案。
- README 與 `skills.json` 沒有遺漏新增或移除的 skill。
- `.claude-plugin/marketplace.json` 與 `SKILL.md` 的版本一致。
- 沒有提交 `.env`、token、私鑰或其他敏感資訊。
