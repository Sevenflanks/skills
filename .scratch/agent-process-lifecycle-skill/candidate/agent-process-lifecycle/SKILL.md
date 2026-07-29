---
name: agent-process-lifecycle
description: Use when lifecycle-decision routing is needed for an Agent-caused local OS process: a foreground local command may hang or outlive the initiating tool call, or a lingering, zombie, or unclear-owner local process needs cleanup or reconciliation. On Windows, classify owner, select the first viable execution tier, and handle readiness, Stop, Preserve, handoff, or reconciliation. On non-Windows, classify only to hand off or block before launch; do not perform lifecycle execution. Do not use for synchronous commands or when merely observing or using an external or runtime-managed resource whose owner and lifecycle contract are already clear.
disable-model-invocation: true
license: MIT
metadata:
  author: sevenflankse
  version: 1.0.0-candidate.10
---

# Agent Process Lifecycle Candidate

This is a scratch-only, manually invoked candidate for ticket 10. It is not a
published skill, production helper, alias, compatibility path, or release
candidate. Do not add it to a catalog, marketplace, published skill directory,
or automatic model-invocation inventory.

## Candidate Test Entry

Use this entry only after a maintainer explicitly loads
`agent-process-lifecycle` for a supplied lifecycle scenario. Produce one
concise lifecycle decision result. Do not use this candidate to execute a
process lifecycle operation.

This candidate never executes a managed or external lifecycle operation. It
only classifies an owner, selects a formal owner contract, and returns a
decision or handoff for the maintainer to execute outside this candidate.

For an excluded request, return:

```json
{
  "applicable": false,
  "lifecycle_fact_bundle_created": false,
  "lifecycle_actions": []
}
```

## Reasoning-Only Entry Check

Before the first candidate long-lived launch decision, reason from the task,
declared configuration, and already-provided owner contract. Do not inspect the
OS, probe a PID or port, run a lifecycle shell command, or poll.

Exit without a lifecycle decision when the command is synchronous and waits for
exit, or when the task merely observes or uses an external or runtime-managed
resource whose owner and lifecycle contract are already clear. On this excluded
path, do not create a lifecycle fact bundle.

For an applicable lifecycle decision, keep a task-local fact bundle only while
the repo, worktree, HEAD, working directory, launch configuration,
environment, launcher, wrapper, execution tool, argument mode, launch
behavior, owner identity, owner contract, owner state, requested decision, and
freshness remain known and unchanged. Invalidate it before the next relevant
decision after any of those changes, an exit, crash, timeout, session
interruption, previous failure, stale or unknown freshness, or an observation
that contradicts it.

## Platform Gate

`1.0.0` supports lifecycle execution only on Windows. On non-Windows, perform
only bounded owner classification from information already available in the
task. Do not inspect the OS, launch, terminate, issue a lifecycle shell call,
or invent platform mechanics.

If a managed or external owner is identifiable, hand off to that owner. If it
is not identifiable, block before launch. In either case, include platform,
requested lifecycle need, identified owner or contract gap, an explicit no
launch or termination statement, missing safety evidence, at least one
non-command alternative, next owner, and unresolved items.

For a non-Windows request with no identifiable owner, return:

```json
{
  "action": "blocked",
  "stage": "pre-launch",
  "platform": "non-Windows",
  "requested_lifecycle_need": "self-managed lifecycle execution",
  "identified_owner": null,
  "contract_gap": "No managed or external owner contract is identifiable.",
  "launch_performed": false,
  "termination_performed": false,
  "os_inspection_performed": false,
  "lifecycle_shell_calls": [],
  "missing_safety_evidence": ["identified owner", "verified lifecycle contract"],
  "alternative": "Transfer ownership to a user, IDE, or verified external owner.",
  "next_owner": "maintainer",
  "unresolved_items": ["owner classification"]
}
```

For a non-Windows request with an identifiable managed or external owner,
return:

```json
{
  "action": "handoff",
  "stage": "pre-launch",
  "platform": "non-Windows",
  "requested_lifecycle_need": "managed lifecycle execution",
  "identified_owner": "managed-or-external",
  "contract_gap": null,
  "launch_performed": false,
  "termination_performed": false,
  "os_inspection_performed": false,
  "lifecycle_shell_calls": [],
  "missing_safety_evidence": [],
  "alternative": "Use the identified owner's documented lifecycle interface.",
  "next_owner": "identified owner",
  "unresolved_items": []
}
```

## Windows Candidate Gate

Select only the first positively verified tier: managed lifecycle, external
launcher, then Windows self-managed helper. A verified managed lifecycle or
external launcher must provide an owner contract and a fresh current-run
binding for the selected operation. Do not race tiers or fall through until the
prior result is stopped, preserved or handed off, or explicitly unresolved.

Before launch, require either an identity-bound Stop disposition or a Preserve
disposition with a later-cleanup owner and handoff contract. Do not use a PID,
name, port, tool timeout, process liveness, or fixed sleep as proof of
ownership, readiness, detachment, or termination authority.

When a verified managed or external owner is selected, return only the selected
owner contract and a handoff decision. Do not invoke that contract. This
candidate does not add OS inspection or lifecycle shell calls. Keep lifecycle
results separate from downstream workload or browser QA results.

## Helper-Unavailable Block

The Windows self-managed helper is not production-implemented or production-
accepted in this candidate. If the first otherwise viable path requires that
helper, stop before launch. Do not create a helper, call a prototype, create a
stub, or supply a substitute publication path.

Return this result shape:

```json
{
  "action": "blocked",
  "stage": "pre-launch",
  "failure_kind": "production-helper-unavailable",
  "reason": "The Windows self-managed helper has no production implementation and has not passed the required production acceptance contract.",
  "launch_performed": false,
  "termination_performed": false,
  "os_inspection_performed": false,
  "lifecycle_shell_calls": [],
  "next_owner": "maintainer",
  "unresolved_items": ["production helper implementation", "production helper acceptance evidence"]
}
```

Prototype feasibility is not production acceptance. Do not present prototype
code, prototype facts, or prototype evidence as a production implementation or
as proof that this blocked result may launch a process.
