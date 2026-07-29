# 13 — 停止具有效 authority 的 owned process tree

**What to build:** 讓具有已驗證 live authority 的 Finalize Stop，依序支援 graceful Stop、必要時 bounded forced Stop，並只終止目前 owned workload tree。它保留 unrelated sentinel，回報 scoped tree 是否清空；本 ticket 只涵蓋 valid-authority behavior，不處理 comprehensive malformed、stale 或 authority mismatch rejection matrix。

**Blocked by:** 12, 在 Launch 建立 fail-closed ownership

**Status:** ready-for-agent

- [ ] valid-authority Finalize Stop 在相容的 session 與 security context 中重新取得 live binding，並在 termination 前完成必要 validation。
- [ ] graceful Stop 成功時不執行 forced termination；graceful action 缺少、失敗或逾時時，才在 bounded path 進入 forced Stop。
- [ ] Stop 終止該 run 的 root 與 children，且 unrelated sentinel 維持存活。
- [ ] Stop 使用同一 live authority 完成 graceful wait、必要的 forced termination 與 empty-tree confirmation，並回報 scoped tree 已清空。
- [ ] Stop 完成後，該 run 的 root、children、named ownership object 與 temporary artifacts 都已清空。
- [ ] valid-authority happy path 不使用 PID-only、name-only、port-only、broad scan、常態 polling 或 close-triggered termination。
