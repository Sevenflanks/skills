# Lifecycle Failure And Handoff

Read this reference only for a non-Windows block or handoff, an external owner
handoff, no viable Windows tier, or an escalation: ownership ambiguity,
readiness failure, owner conflict, unexpected exit, wrapper ambiguity, shutdown
transfer. Do not load it for an ordinary excluded, managed, natural-completion,
or downstream-separation result.

## Targeted Evidence

Freeze launch and fallback while collecting evidence from the selected owner
contract or current binding. Preserve only the evidence needed to explain the
failure: failure kind, selected binding or owner interface, current resource
state, cleanup attempt and result, relevant logs or record path, and the next
owner. Do not perform a broad OS scan or construct a PID tree unless the
selected owner contract itself supplies that scoped evidence.

## Reconciliation Before Fallback

For a failed execution tier, use this order:

1. Freeze another launch or fallback.
2. Preserve targeted evidence.
3. Query the selected owner contract or current binding.
4. Assign exactly one terminal disposition: `stopped`, `preserved`, `handoff`,
   or `unresolved`.
5. Only after that terminal disposition may a lower tier be reconsidered.

`unresolved` is a valid safe terminal result. Do not rename it to completion,
and do not terminate a resource when current identity evidence no longer proves
authority.

## Callback Facts

For failure, block, Preserve, handoff, or unresolved results, include
`failure_kind`, `cleanup_attempt`, `cleanup_result`, `evidence_paths`,
`final_disposition`, `later_owner` when applicable, `next_owner`,
`unresolved_reason`, `unresolved_items`, `lifecycle_result`, and caller-owned
`downstream_result`. Keep
`downstream_result` unchanged; use `null` when the caller supplied none. The callback reports lifecycle responsibility; it
does not add a lifecycle action.

`final_disposition` is always an object with `requested` (`Stop` or Preserve)
and `status`, not a scalar. Normal callbacks align its status with the completed
`lifecycle_result`; after atomic Preserve publication succeeds, exact
temporary-artifact cleanup may instead leave `lifecycle_result.status` as
`unresolved` while `final_disposition.status` stays `preserved`. In that mixed
result, include the binding, record, stdio, readiness, later owner, and safe
later Stop method; do not claim the handoff if publication is unchanged or
unknown. An external handoff additionally includes `owner_binding`,
`identified_owner`, and `failure_kind: "external-owner-handoff"`. These facts
keep the later owner and lifecycle/downstream separation machine-readable.

## Non-Windows Payload

On non-Windows, return a complete payload without OS inspection, lifecycle
shell calls, launch, or termination. Include `platform`,
`requested_lifecycle_need`, `identified_owner` or `contract_gap`,
`launch_performed: false`, `termination_performed: false`,
`os_inspection_performed: false`, `lifecycle_shell_calls: []`,
`missing_safety_evidence`, a command-free `alternative`, `next_owner`, and
`unresolved_items`.

When an owner is identifiable, use `action: "handoff"`; otherwise use
`action: "blocked"` with `stage: "pre-launch"`. Do not invent Linux, macOS,
or other platform mechanics. Use `stage: "pre-launch"` for both outcomes.
Where an external owner is identifiable, normalize it as
`identified_owner: "external-owner"` and set `contract_gap: null`; where none
is identifiable, provide the concrete `contract_gap` instead.

## Responsibility Boundary

Do not report Browser QA completion, pass/fail, screenshots, console or network
verdicts, browser close sequencing, or error severity classification. Those are
caller concerns. This reference only preserves lifecycle evidence and transfers
or resolves lifecycle responsibility.
