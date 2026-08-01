# 18 — Atomic publication 完整 inventory

**What to build:** 在所有必要 behavioral evidence 與 gates 已存在且通過後，以 atomic publication 將舊 published skill 替換為唯一完整的 `agent-process-lifecycle` `1.0.0` inventory。Publication 移除舊 entry，並一次暴露相互同步的 instructions、references、evals、helper artifacts、catalog、README 與 marketplace metadata；本 ticket 驗證既有 evidence，不重算 routing benchmark 或 runtime acceptance。

**Blocked by:** 16, 完成 model-visible instructions 與 eval migration; 17, 執行 routing release gate

**Status:** ready-for-agent

**Decision, 允許組合驗證:** Ticket 16 validates the unchanged instruction body, references, and evals. Ticket 17's final passing gate validates the replacement description from PR #13 HEAD `de659cc`. Before publication, a deterministic preflight must prove that the description is the sole Ticket 16 manifest mismatch and that the old description can reconstruct the Ticket 16 hash. If any other manifest input differs, or the old description cannot reconstruct that hash, stop strictly. No paid/model/routing/runtime suite reruns are authorized.

- [ ] 若 accepted Windows helper、migrated lifecycle evals、runtime acceptance evidence、model-visible behavior evidence 或 routing release gate 任一缺失或未通過，publication 會被阻擋。
- [ ] 舊 skill 從 publication 移除，new inventory 恰好暴露一個 `agent-process-lifecycle` `1.0.0` entry，且沒有 alias、stub、deprecated shell 或 dual publication。
- [ ] main instructions、README、eval metadata、兩份 references、production Windows helper artifacts、root catalog、root README 與 marketplace metadata 全部存在且互相一致。
- [ ] publication check 只驗證既有 routing 與 runtime evidence，不重新執行或重算那些 suites；missing 或 stale evidence 會造成 publication failure。
- [ ] `npm run validate` 通過 structural consistency check，但其成功不會被當成 behavioral gates 的替代品。
- [ ] 任一 artifact 或 consistency check 失敗時，不會對外留下部分完成的 old-or-new inventory。
