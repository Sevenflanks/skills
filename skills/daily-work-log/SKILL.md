---
name: daily-work-log
description: Use when the user wants a daily work log, wants today's work summarized from OpenCode sessions, git commits, PRs, or issues, or asks what was worked on across repos in Windows/OpenCode. Helps agents collect session-derived repos, gather cross-branch git history, supplement PR and closing-issue context with GitHub CLI, then compress everything into grouped daily log bullets.
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.4
---

# Daily Work Log

This skill turns local OpenCode activity, cross-branch git history, and GitHub PR context into a concise daily work log. Keep collection deterministic: use the bundled PowerShell helper to emit pure JSON first, then convert that JSON into the final human-readable log.

## When to use

Use this skill when:

- The user asks for a daily work log, work journal, standup summary, or asks what was done today.
- The user wants work summarized from OpenCode sessions, git commits, PRs, or issues.
- The user needs repo-grouped bullets such as `owner/repo`, `repo-a`, or similar repository sections.
- The environment is Windows / PowerShell / OpenCode and repeatable local evidence collection matters.

Do not use this skill when:

- The user wants a changelog for only one known commit or one PR.
- The user already provides the exact final text and only wants wording edits.
- The user asks to write the report to a file by default. This skill returns the report in-chat first; file output is optional only when explicitly requested.

## Core rule

Do not hand-assemble repo, commit, or PR data from memory. Run the helper script first and treat its JSON as the source of truth. In `session` source mode, repo discovery queries `opencode db --format json` for session evidence first. If GitHub CLI is unavailable or unauthenticated, stop and recommend installing or logging into `gh` unless the user strongly insists on degraded output. If repo discovery is partial, report the gap explicitly instead of guessing.

## Workflow

1. **Recall collection preferences before collecting**
   - Before running the helper, try to recall user or project-specific daily-log collection preferences.
   - Search terms should include `daily-work-log`, `工作日誌`, `日誌`, the current working directory, user-mentioned repo / project names, `scan root`, and `repo discovery`.
   - If useful context is found, translate it into helper parameters or final-summary rules.
   - If recall is unavailable, fails, or returns no useful result, stay silent and continue with the default helper workflow.
   - Do not add project-specific rules to this skill; project-specific collection habits belong in memory.

2. **Confirm scope and defaults**
   - If the user does not specify a clear time range, default range is today in the configured timezone.
   - This default is about missing explicit time range, not about auto-triggering on completely blank input.
   - The helper defaults to `Asia/Taipei`; override `From`, `To`, or `Timezone` when the user needs another range or timezone.
   - Allow overrides for `From`, `To`, repo source mode, or scan roots when the user asks.
   - Default repo source mode is `session`; fallback or broader discovery can use `scan` or `mixed`.
   - In `session` mode, the helper asks `opencode db --format json` for session evidence before reading any file-based OpenCode sources.
   - If the DB command is unavailable, fails, or returns invalid JSON, fallback order is DB, then `storage/directory-readme`, then OpenCode logs.
   - If the DB query succeeds and returns empty `[]`, treat that as authoritative for session discovery and do not fallback to file-based sources.
   - Default `authorScope` is `current`; broad identity matching uses current-user git config and GitHub viewer evidence when available.
   - If the current identity cannot be resolved, the helper warns and falls back to all authors instead of silently pretending current-user filtering happened.

3. **Run the bundled collector**
   - Use `skills/daily-work-log/scripts/collect-daily-work-log.ps1`.
   - Keep the script output pure JSON on `stdout`.
   - Do not append human text, markdown, or logging noise to `stdout`.
   - In `session` mode, treat session-derived repo discovery as including both session-start directories and touched external repo evidence that can be resolved to git repo or worktree roots from `permission=external_directory` or `permission=read` log entries.
   - In `session` mode, if a session path is a safe aggregate directory rather than a git repo, the collector expands nested git repos / worktrees using fast `.git` marker discovery.
   - The default author scope is the current user. Commits and PRs from other authors are excluded unless they are release / deploy bot commits with PR-chain evidence back to current-user work.
   - If a repo has session evidence but no current-user commits, keep it in the final report as one short agent-written session summary when evidence is sufficient; do not invent details.
   - The collector preserves session-derived evidence with source `session-expanded` when a safe aggregate directory contributes nested repo / worktree matches.
   - The PowerShell collector does not generate natural-language summaries. The agent writes any one-line session summary from `sessionEvidence`.

4. **Inspect collection gaps before writing the summary**
   - Check `meta.ghAvailable` and `meta.ghViewer`.
   - If GitHub CLI is unavailable or not authenticated, stop before writing the daily log. Tell the user to install `gh` or run `gh auth login`, then rerun collection.
   - Continue without GitHub evidence only when the user strongly insists on a degraded report. In that case, state the PR / issue supplement gap explicitly in the final notes.
   - Check repo `warnings` and top-level `warnings` / `errors`.
   - Note repos that are not git repos, repos with session activity but no commits, and repos with commits but no PR/issue supplement.
   - Only include paths that resolve to git repo or worktree roots. Surface skipped or unresolved paths through warnings or final notes.
   - Treat PR supplement as relevant only when it can be tied back to the day's commit / branch / hash evidence; do not attach every updated PR from the same repo.

5. **Summarize by GitHub repo name**
   - Group by GitHub repo name from `repos[].githubRepo` first, such as `owner/repo`.
   - If `githubRepo` is unavailable for a repo, fall back to `repos[].name` repo folder name.
   - Never use absolute paths as final group headings.
   - Prefer short bullets, ideally within 30 Chinese characters.
   - Default to 2-5 bullets per repo. If a repo would exceed that, merge nearby commits into theme-level bullets instead of listing every commit-shaped fragment.
   - Prefer bullets that preserve issue / PR numbers such as `PR #219` or `#217`.
   - Each bullet should be understandable on its own. A reader should understand what changed without needing the previous bullet as context.
   - If a bullet only makes sense together with neighboring bullets, merge them into one clearer sentence or drop the weaker fragment.
   - Keep separate bullets when two changes are materially different.

6. **State data gaps honestly**
   - If the user strongly insisted on continuing without available/authenticated `gh`, explicitly say PR / issue links were not supplemented.
   - If a repo had session activity but no commits, say so.
   - If a directory is not a git repo, say so instead of dropping it silently.

## PowerShell helper invocation

Use PowerShell 7+ and pass an explicit script path. Examples:

```powershell
pwsh -NoProfile -File "<path-to-skill>\scripts\collect-daily-work-log.ps1"
```

Override time range and source mode:

```powershell
pwsh -NoProfile -File "<path-to-skill>\scripts\collect-daily-work-log.ps1" `
  -From "2026-05-29T00:00:00+08:00" `
  -To "2026-05-29T23:59:59+08:00" `
  -SourceMode mixed `
  -ScanRoots "<scan-root>"
```

## Collector JSON shape

Treat collector JSON as source of truth:

- `meta`: `generatedAt`, `timezone`, `from`, `to`, `sourceMode`, `scanRoots`, `ghAvailable`, `ghViewer`, `authorScope`, `currentIdentity`.
- `warnings` / `errors`: global evidence gaps or failures.
- `repos[]`: `name`, `path`, `source`, `isGitRepo`, optional `githubRepo`, optional `sessionEvidence`, `commits[]`, `prs[]`, `warnings[]`.
- `commits[]`: commit evidence from `git log --all`, including `authorEmail`; ignore stash noise before summarizing.
- `prs[]`: PR evidence tied to commit / branch / hash relevance; preserve PR and issue numbers when useful.

## Optional evidence compaction

For high-volume evidence, pipe collector JSON through `scripts/format-daily-work-log-evidence.ps1`. It reads collector JSON from stdin, emits pure JSON, preserves `meta`, `warnings`, `errors`, and returns compact repo evidence: `name`, `githubRepo`, `commitCount`, `shownCommits`, `prs`, `lowSignalPrRefs`, `sessionEvidence`, `warnings`.

```powershell
pwsh -NoProfile -File "<path-to-skill>\scripts\collect-daily-work-log.ps1" |
  pwsh -NoProfile -File "<path-to-skill>\scripts\format-daily-work-log-evidence.ps1" -MaxCommitsPerRepo 8
```

## High-commit repos

When a repo has many commits, summarize themes instead of dumping commits. Use compacted `shownCommits` as evidence, keep `shownCommits.Count <= 8` by default, and turn low-signal PR titles such as `noop` into `lowSignalPrRefs` like `PR #238 [MERGED]` instead of user-facing bullets like `PR #238: noop [MERGED]`.

## Required checks

- Helper script output is valid JSON only.
- When the user does not provide a clear time range, the helper resolves the range to today in the configured timezone.
- Git history collection uses `git log --all`; do not limit to current branch.
- `scan` / `mixed` repo discovery must cover git worktrees as well as normal repos.
- `session` repo discovery must query `opencode db --format json` first.
- DB fallback order is DB, then `storage/directory-readme`, then OpenCode logs, but DB success with empty `[]` is authoritative and does not fallback.
- If `storage/directory-readme` finds no resolvable repo/worktree roots after a DB failure, continue to OpenCode log fallback.
- OpenCode log fallback includes session-start directories plus touched external repo evidence from `permission=external_directory`, `permission=read`, and `permission=read-only` paths when they resolve to git repo or worktree roots.
- Only paths resolvable to git repo or worktree roots are included in repo results.
- Repo discovery gaps, skipped paths, and partial evidence are reported through warnings and final notes.
- Stash noise such as `refs/stash`, `index on ...`, or `untracked files on ...` is excluded from summary-worthy commits.
- GitHub supplement is required by default. If `gh` is unavailable or unauthenticated, stop and recommend installing GitHub CLI or running `gh auth login` unless the user strongly insists on continuing without GitHub evidence.
- GitHub supplement is filtered by commit / branch / hash relevance; do not attach unrelated updated PRs from the same repo.
- Release / deploy bot commits are only included when PR-chain evidence ties them back to current-user work.
- Missing GitHub supplement is reported as a warning, not silently ignored.
- If no current-user identity can be resolved, warn that `authorScope` fell back to `all` and summarize all authors from the collected evidence.
- Repos with session evidence but no current-user commits remain eligible for one short agent-written session summary when the evidence is sufficient.
- Final output is grouped by `repos[].githubRepo` GitHub repo name first, with `repos[].name` folder name as fallback only when GitHub repo name is unavailable.
- Final output never uses absolute paths as group headings.
- Each repo defaults to 2-5 bullets unless there is a strong reason to exceed that.
- Final bullets stay concise and preserve PR / issue identifiers when available.
- Final bullets are independently understandable; avoid fragments that only make sense when read together.

## Final output format

Use grouped bullets like this:

```text
- **sevenflanks/repo-a**
  - 修首建參數遺失，PR #49
  - 新增 skills 功能

- **repo-b**
  - 修付款按鈕條件邏輯
  - 合併 PR #219，解 #217
```

If there is a global gap, append a short note after the grouped list, for example:

```text
註：依你的要求先在未登入 GitHub CLI 的狀態下產生日報，PR / issue 關聯未補證。
```

## Examples

```text
Input: 幫我整理今天的工作日誌，最好帶 PR 跟 issue。
Output: Run the PowerShell helper for today's range, inspect JSON warnings, then return grouped bullets by GitHub repo name from `githubRepo`, falling back to repo folder name only when needed.
```

```text
Input: 我想補昨天的日報，範圍改成昨天 00:00 到 23:59，另外掃我的專案根目錄底下 repo 補強。
Output: Run the helper with explicit From/To plus `-SourceMode mixed -ScanRoots "<scan-root>"`, then summarize the resulting JSON into grouped bullets.
```

## Common mistakes

| Mistake | Correct behavior |
| --- | --- |
| 只看目前 branch 的 commit | 一律使用 `git log --all`。 |
| 直接從 commit message 猜 PR / issue 關聯 | 先收 git，再用 `gh` 補 PR 與 closing issues。 |
| helper 腳本同時輸出 JSON 與說明文字 | `stdout` 保持 pure JSON；人類摘要由 skill 產生。 |
| DB 回傳空陣列時繼續讀 log 湊 repo | DB 成功且回傳 `[]` 代表 session discovery 沒有 repo，不 fallback。 |
| DB 查詢失敗就停止 session discovery | 依序 fallback 到 `storage/directory-readme`，再讀 OpenCode logs，並保留 warning。 |
| 看見非 git repo 就忽略 | 明講「今日有 session，非 git repo」。 |
| `gh` 失敗時假裝沒有 PR | 預設停止並建議安裝或登入 `gh`；若使用者強烈堅持才保留 warning 並在最終輸出說明未補證。 |
| `gh` 不存在或未登入時直接降級產生日報 | 先停止並建議安裝 `gh` 或執行 `gh auth login`；只有使用者強烈堅持才降級繼續。 |
| 一律用資料夾名稱當分組標題 | 優先使用 `githubRepo` 的 GitHub repo name，缺失時才 fallback 到 repo folder name。 |
| 把相鄰 commit 片段拆成多條半句 | 合併成一條能單獨理解的日誌句；若無法說清楚就不要列。 |
| 把同一 repo 的 commit 幾乎逐條照抄 | 先歸納成 2-5 條主題句，再保留最重要的 PR / issue。 |
