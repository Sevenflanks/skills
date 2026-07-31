# 09 — 原子發布通過驗證的 self-challenge 0.1.0

**What to build:** 僅在完整 benchmark 通過鎖定門檻後，補齊 published skill 所需文件與 registry metadata，將 `self-challenge` 以一致的 `0.1.0` 原子發布。

**Blocked by:** 08 — 執行鎖定的完整分層 benchmark；只有 release verdict 為 pass 才可開始

**Status:** ready-for-agent

- [ ] `skills/self-challenge/SKILL.md` 包含 `name`、`description`、`license`、`metadata.author` 與 `metadata.version: 0.1.0`，內容與已通過 benchmark 的 candidate 完全一致。
- [ ] 新增 `skills/self-challenge/README.md`，準確說明目的、觸發邊界、兩段式流程、四種 verdict、限制與 controlled-benchmark evidence，不做未驗證的 field-effect 宣稱。
- [ ] 新增合法的 `skills/self-challenge/evals/evals.json`，`skill_name` 等於 `self-challenge`，並保留與發布行為相符的代表性 eval cases。
- [ ] 同步更新 `skills.json`、root `README.md` 與 `.claude-plugin/marketplace.json`；marketplace entry 與 SKILL frontmatter 的版本皆為 `0.1.0`。
- [ ] 發布內容不新增 production dependency、runtime helper、持久化 state、歷史 session mining、multi-agent swarm 或既有 skill integration。
- [ ] 執行 `npm run validate`、JSON parse、版本一致性、placeholder 掃描與 `git diff --check`，所有新增 published-skill invariants 均通過。
- [ ] 若 Ticket 08 未通過、證據不完整或 registry/file-set 無法原子一致，停止發布並明確回報 blocker，不得部分註冊 skill。
