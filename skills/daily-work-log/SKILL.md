---
name: daily-work-log
description: Use when the user wants a daily work log, wants today's work summarized from OpenCode sessions, git commits, PRs, or issues, or asks what was worked on across repos in Windows/OpenCode. Helps agents collect session-derived repos, gather cross-branch git history, supplement PR and closing-issue context with GitHub CLI, then compress everything into grouped daily log bullets.
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.0
---

# Daily Work Log

This skill turns local OpenCode activity, cross-branch git history, and GitHub PR context into a concise daily work log. Keep collection deterministic: use the bundled PowerShell helper to emit pure JSON first, then convert that JSON into the final human-readable log.

## When to use

Use this skill when:

- The user asks for a daily work log, work journal, standup summary, or asks what was done today.
- The user wants work summarized from OpenCode sessions, git commits, PRs, or issues.
- The user needs repo-grouped bullets such as `machine-manager`, `softleader-erp-nex`, or similar folder-based sections.
- The environment is Windows / PowerShell / OpenCode and repeatable local evidence collection matters.

Do not use this skill when:

- The user wants a changelog for only one known commit or one PR.
- The user already provides the exact final text and only wants wording edits.
- The user asks to write the report to a file by default. This skill returns the report in-chat first; file output is optional only when explicitly requested.

## Core rule

Do not hand-assemble repo, commit, or PR data from memory. Run the helper script first and treat its JSON as the source of truth. If GitHub CLI is unavailable or repo discovery is partial, report the gap explicitly instead of guessing.

## Workflow

1. **Confirm scope and defaults**
   - Default range is today in local timezone.
   - Allow overrides for `From`, `To`, repo source mode, or scan roots when the user asks.
   - Default repo source mode is `session`; fallback or broader discovery can use `scan` or `mixed`.

2. **Run the bundled collector**
   - Use `skills/daily-work-log/scripts/collect-daily-work-log.ps1`.
   - Keep the script output pure JSON on `stdout`.
   - Do not append human text, markdown, or logging noise to `stdout`.

3. **Inspect collection gaps before writing the summary**
   - Check `meta.ghAvailable`.
   - Check repo `warnings` and top-level `warnings` / `errors`.
   - Note repos that are not git repos, repos with session activity but no commits, and repos with commits but no PR/issue supplement.

4. **Summarize by folder name**
   - Group by repo folder name only, not absolute path.
   - Prefer short bullets, ideally within 30 Chinese characters.
   - Default to 2–5 bullets per repo. If a repo would exceed that, merge nearby commits into theme-level bullets instead of listing every commit-shaped fragment.
   - Prefer bullets that preserve issue / PR numbers such as `PR #219` or `#217`.
   - Each bullet should be understandable on its own. A reader should understand what changed without needing the previous bullet as context.
   - If a bullet only makes sense together with neighboring bullets, merge them into one clearer sentence or drop the weaker fragment.
   - Keep separate bullets when two changes are materially different.

5. **State data gaps honestly**
   - If `gh` is unavailable, explicitly say PR / issue links were not supplemented.
   - If a repo had session activity but no commits, say so.
   - If a directory is not a git repo, say so instead of dropping it silently.

## PowerShell helper invocation

Use PowerShell 7+ and pass absolute paths. Examples:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\scripts\collect-daily-work-log.ps1"
```

Override time range and source mode:

```powershell
pwsh -NoProfile -File "C:\develop\projects\@sevenflanks-skills\skills\daily-work-log\scripts\collect-daily-work-log.ps1" `
  -From "2026-05-29T00:00:00+08:00" `
  -To "2026-05-29T23:59:59+08:00" `
  -SourceMode mixed `
  -ScanRoots "C:\develop\projects"
```

## Required checks

- Helper script output is valid JSON only.
- Git history collection uses `git log --all`; do not limit to current branch.
- Stash noise such as `refs/stash`, `index on ...`, or `untracked files on ...` is excluded from summary-worthy commits.
- GitHub supplement is attempted only when `gh` is available and authenticated.
- Missing GitHub supplement is reported as a warning, not silently ignored.
- Final output is grouped by folder name only.
- Each repo defaults to 2–5 bullets unless there is a strong reason to exceed that.
- Final bullets stay concise and preserve PR / issue identifiers when available.
- Final bullets are independently understandable; avoid fragments that only make sense when read together.

## Final output format

Use grouped bullets like this:

```text
- **machine-manager**
  - 修首建參數遺失，PR #49
  - 新增 skills 功能

- **cardif-ifrs17-migrate**
  - 修付款按鈕條件邏輯
  - 合併 PR #219，解 #217
```

If there is a global gap, append a short note after the grouped list, for example:

```text
註：GitHub CLI 不可用，PR / issue 關聯未補證。
```

## Examples

```text
Input: 幫我整理今天的工作日誌，按目錄分組，最好帶 PR 跟 issue。
Output: Run the PowerShell helper for today's range, inspect JSON warnings, then return grouped bullets by repo folder with PR / issue numbers where supported.
```

```text
Input: 我想補昨天的日報，範圍改成昨天 00:00 到 23:59，另外掃 C:\develop\projects 底下 repo 補強。
Output: Run the helper with explicit From/To plus `-SourceMode mixed -ScanRoots "C:\develop\projects"`, then summarize the resulting JSON into grouped bullets.
```

## Common mistakes

| Mistake | Correct behavior |
| --- | --- |
| 只看目前 branch 的 commit | 一律使用 `git log --all`。 |
| 直接從 commit message 猜 PR / issue 關聯 | 先收 git，再用 `gh` 補 PR 與 closing issues。 |
| helper 腳本同時輸出 JSON 與說明文字 | `stdout` 保持 pure JSON；人類摘要由 skill 產生。 |
| 看見非 git repo 就忽略 | 明講「今日有 session，非 git repo」。 |
| `gh` 失敗時假裝沒有 PR | 保留 warning，並在最終輸出說明未補證。 |
| 把相鄰 commit 片段拆成多條半句 | 合併成一條能單獨理解的日誌句；若無法說清楚就不要列。 |
| 把同一 repo 的 commit 幾乎逐條照抄 | 先歸納成 2–5 條主題句，再保留最重要的 PR / issue。 |
