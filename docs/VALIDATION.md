# 驗證規則

本 repo 使用 `scripts/validate-skills.mjs` 驗證 skills collection 的基本一致性。

## 執行方式

```powershell
npm run validate
```

或：

```powershell
node scripts/validate-skills.mjs
```

## 檢查項目

驗證腳本會檢查：

- `skills.json` 存在且是合法 JSON。
- `skills.json.schema_version` 為 `1`。
- `skills.json.skills` 是陣列。
- `.claude-plugin/marketplace.json` 存在且是合法 JSON。
- skill `name` 不重複。
- skill `path` 不重複。
- 每個 catalog entry 的 `path` 都存在。
- 每個 skill path 底下都有 `SKILL.md`。
- 每個 skill path 底下都有 `README.md`。
- `SKILL.md` 包含 YAML frontmatter。
- frontmatter 的 `name` 與 catalog 中的 `name` 一致。
- frontmatter 包含非空的 `description`。
- frontmatter 包含 `license`。
- frontmatter 包含 `metadata.author` 與 `metadata.version`。
- `skills.json`、`SKILL.md` 與 `.claude-plugin/marketplace.json` 的版本一致。
- 若存在 `evals/evals.json`，它必須是合法 JSON。
- evals 的 `skill_name` 必須與 skill 名稱一致。
- evals 的 `evals` 欄位必須是陣列。

## CI

`.github/workflows/validate.yml` 會在 push 到 `main` 與 pull request 時執行 `npm run validate`。
