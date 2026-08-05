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

## PR 11 review remediation receipt（2026-08-05）

本節記錄 publication 完成後，由 PR 11 inline review comment `3717512146` 發現 `NamedJobExists` false-absence behavior 所觸發的新一輪已授權 remediation；不改寫上方 Ticket 18 原始 execution receipt。

- PR 11 runtime fix：`cf1aa20`；Windows/Ticket16 evidence commit：`0d8fb34`。`OpenJobObjectW` 現在只有 `ERROR_FILE_NOT_FOUND (2)` 會證明 named Job 不存在，其他 error 會保留為 unresolved，未完成 release probe 的 `named_job_absent` 為 `null`。
- PR 12 rebased head：`c9c1ba47bbe6f94dde323a65d676bec1e0201da3`；12 commits 的 range-diff 全部 `=`，`npm run validate` PASS。
- PR 13 rebased head：`762e80165a6cc0d739144ff9d7cdab277564430f`；4 commits 的 range-diff 全部 `=`，Ticket 17 decision 內 38 個 hash-bound commit blobs 在 old/new heads 間 byte-identical，`npm run validate` PASS。
- PR 14 publication sync commit：`b5fa748`。既有 preflight 在同步前精確因 candidate helper hash 與 candidate/published byte mismatch 而 RED；更新 provenance pins、review receipt assertions 與 published helper 後為 GREEN。
- PR 14 deterministic contracts：tests 16、pass 16、fail 0、`165.8571ms`；PowerShell parser 4/4 PASS；candidate/published helper parity 2/2 PASS；`npm run validate` PASS。
- Windows Ticket 11 至 15 runtime 因 accepted helper source 改變，已在 PR 11 upstream 重新執行並通過 tests 65、pass 65、fail 0、`391432.6759ms`；helper LF-normalized SHA-256 為 `b24ea67d08e765000e4b880b99cdc8ac92a54e62ead1c65537a3905ce9ddcc73`。
- Ticket 16 因 Windows receipt input hash 改變，已在 PR 11 upstream 以 canonical runner 單次重新執行並通過 17/17；receipt LF-normalized hash 為 `7f7091f532027f65b26992cdbc9834237c9c4a1779a0f3d1f5b44d295ae7529e`。
- Ticket 17 routing gate未重跑：benchmark/evaluator sources、trigger inputs、variants、current/candidate `SKILL.md`、exact model-facing description 與已發布 routing artifacts 的 bound commit blobs均未改變；既有 fixed base 仍為 96 valid／0 invalid、candidate +24／-0、parity matched、safety passed、exit code 0。
- PR 14 本身只執行 deterministic publication preflight、parser、byte parity 與 structural validation，未重跑 Windows、Ticket 16 或 Ticket 17 paid/model suites。
- Repository 內 `.omo/` continuation metadata 未修改、刪除、stage、hash 或納入 evidence。既有 abrupt-host-crash 與 same-user malicious tamper non-guarantees 均未改變。

## Access-denied coverage remediation receipt（2026-08-05）

本節補足 GitHub review `4860484721` 明示要求的 `access-denied` 負向測試；不改寫前兩份 publication／review remediation 歷史收據。

- PR 11 explicit coverage commit：`10d173b`；Windows/Ticket16 evidence commit：`23a8e49`。Ticket-only instrumented helper copy以 `Marshal.SetLastPInvokeError(5)` 與 zero handle進入未修改的 production `NamedJobExists` classification block；未新增 production seam。
- Historical pre-fix focused run：tests 3、pass 0、fail 3、`8658.4561ms`；current focused run：tests 3、pass 3、fail 0、`9903.1805ms`。Launch 與 Finalize public evidence 均包含 `Win32 error 5` 且 `named_job_absent = null`。
- 第二次 Windows Ticket 11 至 15 acceptance：tests 65、pass 65、fail 0、`481610.4723ms`；parser 2/2、Node syntax 6/6、protected fixture residue、volume-root residue與 `npm run validate` 均 PASS。
- Candidate／published helper bytes未變；LF-normalized helper SHA-256 仍為 `b24ea67d08e765000e4b880b99cdc8ac92a54e62ead1c65537a3905ce9ddcc73`。
- 第一個本輪 Ticket16 canonical attempt 因 `finite-detached-timeout-stop.lifecycle_actions` 單一 model assertion失敗而在 publication staging前 fail-closed；既有 canonical 17/17 evidence與 lock/staging state均未受影響。維護者另行明確授權一次額外完整 rerun，該 run通過 17/17並原子發布；新 receipt hash為 `e991856e96cbdad4448b449dfe8b596a4bb9cbab6e7b2b2f4117c12c8e34dd3f`，routing hash仍為 `d9f6ff89ef0edae2ef3bf39b70de60f412a159ba309f89d74ec71be396a08be9`。
- PR 12 rebased head：`58dd87f0e889e119847fd549f3245f67901923a0`；12 commits range-diff全部 `=`，validate PASS。
- PR 13 rebased head：`6a87f34b6b2df14b6f6940413acafc4ffb747593`；4 commits range-diff全部 `=`，Ticket17 的38個 bound commit blobs byte-identical，validate PASS，因此未重跑96-trial routing gate。
- PR 14 rebase後既有8 commits range-diff全部 `=`；access-denied publication preflight commit為 `90ec231`。Candidate＋publication contracts tests 16、pass 16、fail 0、`176.6319ms`；PowerShell parser 4/4、candidate/published parity 2/2與 `npm run validate` 均 PASS。
- Published helper與 holder相對前一 PR 14 head的 blobs未改變；本輪 PR 14只更新 deterministic preflight與本收據。
- `.omo/` continuation metadata未修改、刪除、複製、stage、hash或納入 evidence；既有 non-guarantees未改變，也不宣稱 alternate-account或真實 ACL identity-switch coverage。
