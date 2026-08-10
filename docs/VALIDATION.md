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

如需單獨檢查 tracked path 預算，可執行：

```powershell
node scripts/check-tracked-path-budget.mjs
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
- `git ls-files -z` 取得的每個 repository-relative tracked path 長度必須不超過 `185` 個字元；成功時會輸出觀察到的最大長度與路徑。

## CI

`.github/workflows/validate.yml` 會在 push 到 `main` 與 pull request 時於 Ubuntu 執行 `npm run validate`。同一 workflow 也會在 Windows runner 將 source checkout 實際 clone 到 `$env:RUNNER_TEMP`，並以 command-scoped `core.longpaths=false` 驗證 clone 可完成、工作樹乾淨且 HEAD 與來源一致；暫存 clone 一律在 `finally` 清理。
