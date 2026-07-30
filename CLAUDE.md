# Claude Instructions

本檔與 [`AGENTS.md`](AGENTS.md) 使用相同維護原則。處理此 repo 時，請優先遵守 `AGENTS.md` 的結構、catalog 與驗證規則。

完成任何 skill 或 catalog 變更後，請執行：

```powershell
npm run validate
```

## Agent skills

### Issue tracker

Issues 與 specs 使用 repo 內的 Local Markdown tracker。See `docs/agents/issue-tracker.md`.

### Triage labels

Triage 使用五個 canonical role strings。See `docs/agents/triage-labels.md`.

### Domain docs

本 repo 採 single-context layout，使用 root `CONTEXT.md` 與 `docs/adr/`。See `docs/agents/domain.md`.
