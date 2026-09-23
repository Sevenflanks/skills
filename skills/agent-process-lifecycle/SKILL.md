---
name: agent-process-lifecycle
description: "Agent 啟動的前景本機命令可能卡住（may hang）、跨越 tool call，短命 CLI 留下 child，或需要 cleanup／reconciliation 時，進行 lifecycle routing；明確要求 lifecycle decision 時也適用。Windows 優先採有 current-run ownership 與 Stop 的 owner contract；跨 tool Preserve 才需背景返回能力，缺證據的特殊自脫離路由可診斷。non-Windows 僅分類、handoff 或 launch 前 blocked。所有工作已正常結束的同步命令，以及已有完整 external/runtime owner 契約的資源，直接依原 owner 處理。"
license: MIT
metadata:
  author: sevenflankse
  version: 1.1.1
---

# Agent Process Lifecycle

## Lifecycle Decision Contract

Apply the ordered flow below to lifecycle decisions for Agent-caused local OS
processes. Return concise machine-readable lifecycle facts where practical, and
keep the lifecycle result separate from the caller-owned downstream result.

Do not own Browser QA. Browser, page, screenshot, console, network, accessibly
checks, and downstream success policy belong to the caller. A downstream
failure never removes the lifecycle owner’s cleanup responsibility.

When returning JSON, use the public facts relevant to the selected path. Keep
`lifecycle_result` and caller-owned `downstream_result` separate. The following
names are the stable public vocabulary when relevant: `applicable`,
`fact_bundle`, `action`, `stage`, `platform`, `selected_tier`, `failed_tier`,
`fallback_tier`, `owner_binding`, `lifecycle_actions`, `final_disposition`,
`binding`, `record_path`, `stdio`, `readiness`, `later_owner`, `stop_method`,
`evidence_paths`, `missing_safety_evidence`, `next_owner`, `unresolved_items`,
`lifecycle_result`, `downstream_result`, `minimum_outcomes`, `failure_kind`,
`cleanup_attempt`, `cleanup_result`, `unresolved_reason`, and `unresolved_items`.
Preserve caller-supplied
`downstream_result` values unchanged. Always include `downstream_result`; use
`null` when the caller supplied none.

For model-visible JSON, normalize public values instead of substituting close
synonyms. Use `Windows` or `non-Windows` for `platform`; use
`managed-lifecycle`, `external-launcher`, `external-owner`, or `windows-self-managed` for
`selected_tier`; and represent `owner_binding` as an object with a `kind`.
Represent `final_disposition` as `{ "requested": "Stop" | "Preserve",
"status": "..." }`; normally it records the same completed disposition as
`lifecycle_result`, but Preserve publication and temporary-artifact cleanup are
separate results. After atomic Preserve publication succeeds,
`final_disposition.status` remains `preserved` when exact temporary-artifact
cleanup is `unresolved`; do not claim handoff when publication is unchanged or
unknown. Make `lifecycle_result` an object with a `status`, not a bare string. Use
`planned`, `stopped`, `preserved`, `exited`, `handoff`, `blocked`, or
`unresolved` as the relevant status.
For every executable tier, return exactly this object at `minimum_outcomes`:
`ownership_binding`, `stdio`, `readiness`, `observation`, `disposition`,
`cleanup_or_handoff`, and `lifecycle_callback`; every value is exactly
`owner handled`, `not applicable`, or `escalated`.

## 1. Applicability And Entry Check

Before the first relevant decision, reason only from the task, declared
configuration, and an already-provided owner contract. Do not perform a
per-command audit, OS inspection, PID or port probe, lifecycle shell call, or
polling to decide applicability. 標準測試與新服務若已有涵蓋當次 resource
ownership、bounded test 與同 tool Stop cleanup 的契約，可直接依契約執行；
跨 tool Preserve 才需背景返回與 later Stop 證據，不一律要求歷史 probe。

Exit with no lifecycle fact bundle only when the command and *all work it
started* finish normally with no resource left to manage, or when the task
only uses an external/runtime-managed resource whose owner and complete
contract are already clear. A short-lived CLI's exit code, HTTP response, or
readiness signal does not exclude its still-running descendant. Return:

```json
{
  "applicable": false,
  "lifecycle_fact_bundle_created": false,
  "lifecycle_actions": []
}
```

區分可重用的 route capability 與每次執行的 resource facts。完整 owner contract
或已證實的執行方式可在相同 route、tool、mode、相關環境及契約未變時沿用；普通 app
code edit 或 HEAD 變更本身不使其失效，也不要求重做 host return-live 測試。
每次啟動仍要取得 fresh current-run binding、readiness 與 current Stop evidence。
route／tool／mode、相關環境或 owner contract 改變時，舊 route 的證據不直接
適用；先按所選 Stop 或 Preserve 評估新 route 契約，完整即可選 tier。
同一 route 已知 host-return 被 child 卡住、ownership 或 Stop 契約失效時，
先處理當次 binding，受影響能力需該 route 的 targeted evidence 才能恢復。
timeout 先釐清原因；未知原因僅將可能受影響的能力列為待查，不泛化失效。
單次 app readiness 失敗或 downstream assertion 失敗只處理當次 resource，
不自動否定已驗證的 host-return capability。背景返回未知且其他安全條件
齊備的特殊 Preserve route 可做 bounded 診斷，不使新服務因無歷史 probe 卡住。
exit、crash、timeout、session interruption 或 owner state 變化也會使該次
resource facts 失效；先處理既有 binding 的 reconciliation，再決定後續操作。

當事件使 resource facts 失效，標記受影響的 bundle，並在下次相關決策前重做
reasoning-only entry check；不可沿用過時的 owner、configuration 或 readiness。

When a scenario is limited to an invalidating owner change, return
`fact_bundle.invalidated: true`, `fact_bundle.invalidation_event:
"owner-change"`, and `fact_bundle.entry_check_repeated: true`, then stop after
the reasoning-only entry check. This pure invalidation result reads neither
reference and does not select a tier. A normal managed result reports
`owner_binding.kind: "opaque-current-run"` and the owner-handled
`minimum_outcomes` at top level. An external handoff reports
`current_run_cleanup_claimed: false`. For Preserve, handoff, blocked, failure,
or unresolved callbacks, include the machine-readable responsibility facts
defined by `references/failure-and-handoff.md`; never collapse them into prose.

## 2. Platform Gate

`1.1.1` supports lifecycle execution only on Windows. On non-Windows, perform
only bounded owner classification from information already available in the
task. Do not inspect the OS, launch, terminate, issue a lifecycle shell call,
or invent platform mechanics.

For every non-Windows block or handoff, read
`references/failure-and-handoff.md` before responding. Return the complete
command-free payload there: platform, requested lifecycle need, identified
owner or contract gap, explicit no-launch/no-termination facts, zero OS
inspection, empty lifecycle shell calls, missing safety evidence, a non-command
alternative, next owner, and unresolved items. Do not read the Windows
reference on this path.

## 3. Windows Tier Selection

On Windows, select the first positively verified tier in this order:

1. Verified managed lifecycle.
2. Verified external launcher.
3. Windows self-managed helper.
4. Blocked or handoff.

A managed or external tier is viable only when its current contract can produce
a fresh current-run scoped binding covering the resource that *remains* after
the launcher exits, with a viable finalization method. 同 tool Stop 須由
owner contract 涵蓋 bounded test 與 identity-bound cleanup；host tool 可在
cleanup 後才返回。跨 tool Preserve 才需 child 存活時 host 返回、named later
owner 與 safe later Stop 的契約或同 route return-live 證據。兩者每次 launch
均需新鮮 binding、readiness 與 Stop evidence。Do not reconstruct
a PID tree for a managed owner. A normal managed result uses its opaque binding,
sets `os_inspection_performed: false` and `lifecycle_shell_calls: []`, and
reads neither reference.

When managed lifecycle is not viable but a verified external launcher has the
first viable current-run contract and fresh binding, select
`selected_tier: "external-launcher"` before self-managed work. Report its
official-interface ownership and all seven `minimum_outcomes`; this is an
executable current-run tier, not an external-owner handoff. It uses no extra OS
inspection or lifecycle shell calls; report `os_inspection_performed: false`
and `lifecycle_shell_calls: []`, with
`owner_binding.kind: "official-interface-current-run"`.

For a short-lived launcher, decide from its declared spawn/owner contract
whether a descendant survives. A launcher exit does not establish descendant
exit or transfer ownership. The Windows helper's `Launch` observes its root
process before readiness; do not assume it can adopt a child whose launcher
already exited. Select a tier only if its binding really covers the descendant.
If no tier does, block or hand off *before* launch. Do not add a per-command OS
scan or replace a requested Preserve with Stop to make a tier appear viable.
只有背景返回未知，正式 workload 已有涵蓋 child 的 owner／Stop 契約，且
診斷 fixture 有合法 owner、獨立 bounded lifetime 與 Stop 的特殊自脫離
route，可先讀 `references/failure-and-handoff.md`，並按第 5 節描述診斷
步驟與尚缺證據；
診斷只能確認 return-live，不能補足正式 workload 的 ownership 或 Stop
契約。正式 owner／Stop 缺口須取得適用契約，否則 pre-launch block/handoff。

An identified external or runtime owner is a handoff, not current-run cleanup.
Read `references/failure-and-handoff.md` immediately before that handoff. If no
tier has a verified owner and viable Stop or Preserve disposition, read that
reference and return a pre-launch block with `failure_kind:
"no-viable-tier"` and the missing evidence.

For an identified external-owner handoff, return
`failure_kind: "external-owner-handoff"`, `cleanup_attempt: "not-attempted"`,
and `cleanup_result: "handoff"` with the structured Preserve disposition and
all callback facts. This classifies responsibility transfer; it is not a claim
that the current run failed to clean up its own resource.

Never race tiers. A failed tier must first reach `stopped`, `preserved`,
`handoff`, or `unresolved` through reconciliation before another tier is
eligible. For a higher-tier failure followed by self-managed fallback, read
`references/failure-and-handoff.md` first, reconcile the failed tier, then read
`references/windows-self-managed.md` only after self-managed fallback becomes
eligible.

## 4. Selected Windows Self-Managed Branch

Only after selecting the self-managed tier, read
`references/windows-self-managed.md`. This is the only reference needed for an
ordinary self-managed Stop path. Do not read it for excluded, managed,
external-handoff, or non-Windows paths.

Before `Launch`, choose one final disposition:

* `Stop` requires an executable identity-bound finalization path.
* `Preserve` requires a named later owner and safe handoff contract. 跨 tool
  Preserve 須確定 host 在 child 存活時返回；契約未涵蓋此能力的特殊短命 CLI
  留 child／自脫離 route，才需同 route 實測。Stop 不以此為門檻。

Neither PID, name, port, process liveness, foreground return, fixed sleep, nor
tool timeout proves detachment, readiness, ownership, or termination authority.
Reject a foreground command and timeout-as-background shortcut. If neither
disposition is viable, block or hand off before launch.

## 5. Execute And Finalize

Every launch obtains a fresh current-run binding. The selected owner supplies
stdio isolation and, when the workload needs it, one bounded
workload-specific readiness signal and deadline. Spawn or liveness is not
readiness.

For a temporary Stop route involving a short-lived launcher, keep the selected
owner's descendant binding through the *same tool call* and invoke its
identity-bound Stop in `finally`, including after downstream failure. Confirm
cleanup with the owner contract; an HTTP 202, successful CLI exit, or a single
failed readiness/probe check is neither OS exit nor completed Stop. On
readiness failure, cancellation or interruption reconcile through the binding;
interruption may prevent `finally` from running, so tests need an independent
bounded fixture lifetime/finalization and must retain unresolved evidence.
Never substitute shell timeout for cleanup. 契約未涵蓋背景返回的特殊自脫離
route 要 Preserve，需同 route/host tool return-live 證據、named later owner 與 safe
Stop；shell-end marker 不等於 caller 收到完整 tool result。只有背景返回
未知、正式 owner／Stop 契約齊備且 fixture 有合法 owner 與 Stop 時，可先用
獨立 bounded、能在 interruption 後自行結束的 fixture 做 targeted 診斷，
並在診斷後核對 host completion、child identity 與 OS exit；未取得證據前不啟動
正式 Preserve。可用既有 `lifecycle_result.status: "planned"` 表示只規劃診斷，
以 `missing_safety_evidence` 說明正式 launch 尚缺證據；診斷 fixture 有獨立
bounded lifetime，不須先證明該未知 route 可返回。若同一 route 已證實
等到 child exit 才返回，或 timeout 原因未知且可能影響 host-return，
依 failure reference 調查受影響能力；如有未清理 binding 則先 reconcile。
不能以未涵蓋該失敗 route 的泛稱契約覆蓋、shell timeout
代替 detach，或靜默將 Preserve 改為 Stop。

Windows self-managed 流程若只有專案內的寫入授權，record 與 stdio 就留在該範圍。
helper 可保護本次建立的 artifacts，但不修改既有目錄 ACL、不要求 per-user
初始化，也不把完整 ancestor ACL audit 當成啟動 authority。檢查聚焦於 artifact
boundary；遇到 reparse 或 identity mismatch 時拒絕操作。

For Windows self-managed work, public lifecycle actions are only `Launch` and
`Finalize`. `Stop` and `Preserve` are `Finalize` dispositions, never third
actions. A Stop path finalizes only with live ownership proof. A finite detached
job that naturally exits returns its result and no residue without termination;
termination becomes eligible only after cancellation, timeout, or lost control
and live ownership proof.

For a planned listener Stop, set `foreground_execution_rejected: true` and
`timeout_is_not_detachment: true` as top-level public facts. For a GUI path,
set `resource_kind: "gui"` and `browser_qa_owned: false` as top-level public
facts. For a timed-out job with supplied current
ownership proof, set `termination_allowed: true`,
`termination_trigger: "timeout"`, and `live_ownership_proven: true`; this
decision does not reselect a tier or read a reference. For a natural finite-job
exit, set `natural_completion: true`, `termination_performed: false`,
`resource_residue: false`, include `job_result`, and set
`lifecycle_result.status: "exited"`; it reads neither reference.

For Preserve, read `references/failure-and-handoff.md` after the Windows
reference and before returning the handoff. Deliver the fresh binding, record,
stdio, readiness, later owner, and safe later `Finalize` Stop method. Preserve
is responsibility transfer, not cleanup completion. If atomic publication
succeeds but exact temporary-artifact cleanup is unresolved, retain
`final_disposition.status: "preserved"`, report
`lifecycle_result.status: "unresolved"`, and deliver the handoff facts. Do not
report Preserve when publication is unchanged or unknown.

## 6. Failure, Handoff, And Unresolved

Read `references/failure-and-handoff.md` before handling ownership ambiguity,
readiness failure, owner conflict, unexpected exit, wrapper ambiguity, shutdown
timeout, identity mismatch, residual resource, Preserve, or any handoff. For a
self-managed identity mismatch, read the Windows reference first and the
failure reference second. Preserve targeted evidence; never substitute a new
PID, name, port, or broad OS scan for missing authority.

`unresolved` is a safe terminal lifecycle result. It cannot be rewritten as
clean success. Continue lifecycle finalization when the caller's downstream
work fails, but retain the original `downstream_result` separately.

For an identity mismatch, return `action: "unresolved"`,
`failure_kind: "identity-mismatch"`, `termination_performed: false`, targeted
`evidence_paths`, and `lifecycle_result.status: "unresolved"`. When a scenario
supplies an already-completed lifecycle cleanup and only asks to preserve a
downstream failure, report `lifecycle_result.status: "stopped"` and the
unchanged downstream object without reselecting a tier or reading a reference.

## 7. Contrastive Decisions

* A synchronous build whose entire work has exited is excluded and creates no facts.
* A CLI that exits 0 but leaves a descendant alive requires a binding covering
  that descendant; temporary Stop finalizes in the same tool call.
* A managed current-run binding is selected without a PID dossier or extra
  lifecycle shell work.
* An external runtime-owned service is handed off, never adopted into cleanup.
* A GUI, listener, watcher, or worker follows the same ownership decision; its
  workload kind does not transfer Browser QA responsibility here.
* A naturally exited finite detached job is not terminated. A timed-out owned
  job may use identity-bound Stop through `Finalize`.

## Reference Index

`references/windows-self-managed.md` documents the selected Windows
self-managed `Launch`/`Finalize` contract. `references/failure-and-handoff.md`
documents escalation evidence, reconciliation, handoff, and non-Windows
payloads. This index is discoverability only; do not read either reference
unless its decision site above selects it.
