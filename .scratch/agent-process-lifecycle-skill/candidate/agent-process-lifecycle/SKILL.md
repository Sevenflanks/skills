---
name: agent-process-lifecycle
description: Use when lifecycle-decision routing is needed for an Agent-caused local OS process: a foreground local command may hang or outlive the initiating tool call, a lingering, zombie, or unclear-owner local process needs cleanup or reconciliation, or the task explicitly requests a lifecycle decision for an Agent-started or managed current-run binding. On Windows, select the first viable execution tier and handle readiness, Stop, Preserve, handoff, or reconciliation. On non-Windows, classify an Agent-caused local process only to hand off or block before launch; do not perform lifecycle execution. Do not use for a command that remains synchronous until normal exit, regardless of duration. Do not load this skill merely to classify, Preserve, observe, check status, or use a resource when the prompt already identifies a framework, IDE, Kubernetes, Docker, Windows Service, CI, or other external or runtime owner and states its complete lifecycle contract; follow that owner's contract directly.
disable-model-invocation: true
license: MIT
metadata:
  author: sevenflankse
  version: 1.0.0-candidate.10
---

# Agent Process Lifecycle Candidate

This is a scratch-only, manually invoked candidate for ticket 16. It is not a
published skill, production helper, alias, compatibility path, or release
candidate. Do not add it to a catalog, marketplace, published skill directory,
or automatic model-invocation inventory.

## Candidate Test Entry

Use this entry only after a maintainer explicitly loads
`agent-process-lifecycle` for a supplied lifecycle scenario. Apply the ordered
flow below and return one concise, machine-readable lifecycle decision. A
restricted evaluation fixture may prohibit execution tools; in that fixture,
return the selected lifecycle plan and its public facts rather than attempting
an unavailable operation.

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
`unresolved` as the relevant status. A restricted model-visible fixture plans
rather than performs lifecycle work, so `planned` is its valid final status.
For every executable tier, return exactly this object at `minimum_outcomes`:
`ownership_binding`, `stdio`, `readiness`, `observation`, `disposition`,
`cleanup_or_handoff`, and `lifecycle_callback`; every value is exactly
`owner handled`, `not applicable`, or `escalated`.

## 1. Applicability And Entry Check

Before the first relevant decision, reason only from the task, declared
configuration, and an already-provided owner contract. Do not perform a
per-command audit, OS inspection, PID or port probe, lifecycle shell call, or
polling to decide applicability.

Exit with no lifecycle fact bundle for a synchronous command that waits for
exit, or a task that only observes or uses an external or runtime-managed
resource whose owner and complete lifecycle contract are already clear. Return:

```json
{
  "applicable": false,
  "lifecycle_fact_bundle_created": false,
  "lifecycle_actions": []
}
```

For an applicable lifecycle decision, keep a task-local fact bundle only while
the repo, worktree, HEAD, working directory, launch configuration,
environment, launcher, wrapper, execution tool, argument mode, launch
behavior, owner identity, owner contract, owner state, requested decision, and
freshness remain known and unchanged. Invalidate it before the next relevant
decision after any of those changes, an exit, crash, timeout, session
interruption, previous failure, stale or unknown freshness, or an observation
that contradicts it.

When any invalidating event occurs, mark the bundle invalid and repeat this
reasoning-only entry check before the next relevant decision. Do not reuse
stale owner, configuration, or readiness facts.

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

`1.0.0` supports lifecycle execution only on Windows. On non-Windows, perform
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
a fresh current-run scoped binding for the selected operation. Do not reconstruct
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
* `Preserve` requires a named later owner and safe handoff contract.

Neither PID, name, port, process liveness, foreground return, fixed sleep, nor
tool timeout proves detachment, readiness, ownership, or termination authority.
Reject a foreground command and timeout-as-background shortcut. If neither
disposition is viable, block or hand off before launch.

## 5. Execute And Finalize

Every launch obtains a fresh current-run binding. The selected owner supplies
stdio isolation and, when the workload needs it, one bounded
workload-specific readiness signal and deadline. Spawn or liveness is not
readiness.

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

* A synchronous build that waits for exit is excluded and creates no facts.
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
