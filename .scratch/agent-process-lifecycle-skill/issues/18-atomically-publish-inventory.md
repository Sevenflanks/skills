# 18 — Atomic publication 完整 inventory

**What to build:** 在所有必要 behavioral evidence 與 gates 已存在且通過後，以 atomic publication 將舊 published skill 替換為唯一完整的 `agent-process-lifecycle` `1.0.0` inventory。Publication 移除舊 entry，並一次暴露相互同步的 instructions、references、evals、helper artifacts、catalog、README 與 marketplace metadata；本 ticket 驗證既有 evidence，不重算 routing benchmark 或 runtime acceptance。

**Blocked by:** 16, 完成 model-visible instructions 與 eval migration; 17, 執行 routing release gate

**Status:** completed

**Decision, 允許組合驗證:** Ticket 16 validates the unchanged instruction body, references, and evals. Ticket 17's final passing gate validates the replacement description from PR #13 HEAD `de659cc`. Before publication, a deterministic preflight must prove that the description is the sole Ticket 16 manifest mismatch and that the old description can reconstruct the Ticket 16 hash. If any other manifest input differs, or the old description cannot reconstruct that hash, stop strictly. No paid/model/routing/runtime suite reruns are authorized.

- [x] 若 accepted Windows helper、migrated lifecycle evals、runtime acceptance evidence、model-visible behavior evidence 或 routing release gate 任一缺失或未通過，publication 會被阻擋。
- [x] 舊 skill 從 publication 移除，new inventory 恰好暴露一個 `agent-process-lifecycle` `1.0.0` entry，且沒有 alias、stub、deprecated shell 或 dual publication。
- [x] main instructions、README、eval metadata、兩份 references、production Windows helper artifacts、root catalog、root README 與 marketplace metadata 全部存在且互相一致。
- [x] publication check 只驗證既有 routing 與 runtime evidence，不重新執行或重算那些 suites；missing 或 stale evidence 會造成 publication failure。
- [x] `npm run validate` 通過 structural consistency check，但其成功不會被當成 behavioral gates 的替代品。
- [x] 任一 artifact 或 consistency check 失敗時，不會對外留下部分完成的 old-or-new inventory。

## Execution Result

已完成 verified publication。分支為 `feat/ticket-18-atomic-publication`，publication commit 為 `5a5bb75`，準備範圍為 `cec68b4..5a5bb75`。最終 7-file inventory 為：

- `skills/agent-process-lifecycle/SKILL.md`
- `skills/agent-process-lifecycle/README.md`
- `skills/agent-process-lifecycle/evals/evals.json`
- `skills/agent-process-lifecycle/references/failure-and-handoff.md`
- `skills/agent-process-lifecycle/references/windows-self-managed.md`
- `skills/agent-process-lifecycle/scripts/Invoke-AgentProcessLifecycle.ps1`
- `skills/agent-process-lifecycle/scripts/JobHandleHolder.ps1`

舊 skill 已移除，publication 僅保留上述唯一 `agent-process-lifecycle` `1.0.0` entry，未新增 alias、stub、deprecated shell、compatibility shell 或 dual publication。Ticket 16 evidence 位於 `.scratch/agent-process-lifecycle-skill/candidate/evidence/model-visible-ticket-16/{manifest.json,results.ndjson,summary.json}`，結果為 `17/17`，且僅以 exact description mismatch 重建舊 skill hash。Ticket 17 gate root 為 `.scratch/agent-process-lifecycle-skill/benchmarks/02-trigger-baseline/results/ticket-17-release-gate-20260731T162044Z`；fixed base 為 `96 valid/0 invalid`，candidate 為 `+24/-0`，exit code `0`。Windows acceptance receipt 為 `.scratch/agent-process-lifecycle-skill/candidate/evidence/windows-helper-acceptance.md`；deterministic publication tests `16/16`、parser `2/2` 均已驗證。`npm run validate` 為 `PASS`，範圍僅 structural consistency。Standards review 無 blocking，Spec review `PASS`。

本次未重跑 model、routing 或 Windows runtime suites，也未重跑 behavioral acceptance。未變更 Ticket 17、`.omo`、tag、changelog、alias、stub 或 compatibility-shell。既有 accepted non-guarantees 維持不變：不保證 abrupt host crash 發生於 recoverable record atomic publication 前時能自動恢復或判定所有狀態，也不保證抵抗 same-user malicious tamper。
