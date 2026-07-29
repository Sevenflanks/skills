# 12 — 在 Launch 建立 fail-closed ownership

**What to build:** 讓 Launch 在 workload resume 前建立可驗證的 ownership binding。當 assignment、stdio isolation、readiness 或 atomic record publication 任一項無法安全完成時，同一次 Launch invocation 必須 fail closed、嘗試 cleanup，並回報 cleanup 或 unresolved responsibility，而不是產生誤導性的 success。

**Blocked by:** 11, Launch 與 graceful Finalize Stop

**Status:** ready-for-agent

- [ ] Launch 為 current user 建立 fresh、exclusive 且受 ACL 保護的 binding，並拒絕既有、concurrent、redirected、symlink 或 reparse target。
- [ ] Launch 先建立 `preparing` record，再產生唯一 `Local\` named Job；production workload 不繼承 Job handle。
- [ ] root workload 在 scoped ownership 與 stdio binding 完成 atomic establishment 前不得 resume。
- [ ] assignment、stdio allowlist、readiness 或 record publication 任一 failure 都回傳 failed Launch result，並在同一次 invocation 嘗試 cleanup。
- [ ] cleanup 不完整時回傳 unresolved 與 evidence，不得包裝成 success 或 clean completion。
- [ ] public behavior 不要求 caller 管理 Job handle，也不要求 caller 重建 private ownership protocol。
