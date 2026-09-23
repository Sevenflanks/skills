# Lifecycle Failure And Handoff

Read this reference only for a non-Windows block or handoff, an external owner
handoff, no viable Windows tier, or an escalation: ownership ambiguity,
readiness failure, owner conflict, unexpected exit, wrapper ambiguity, shutdown
transfer. 另於 timeout、identity mismatch、residual resource、Preserve 或
handoff 時讀取；普通 excluded、managed、natural-completion 或
downstream-separation result 不需讀取。

## Targeted Evidence

Freeze launch and fallback while collecting evidence from the selected owner
contract or current binding. Preserve only the evidence needed to explain the
failure: failure kind, selected binding or owner interface, current resource
state, cleanup attempt and result, relevant logs or record path, and the next
owner. Do not perform a broad OS scan or construct a PID tree unless the
selected owner contract itself supplies that scoped evidence.

Short-lived launcher exit (including exit 0), HTTP 202, and one failed probe
are not evidence of descendant OS exit. If the current binding cannot prove
ownership, keep `unresolved` and do not terminate by PID/name/port. When an
interrupt prevents the same-tool Stop `finally` from running, the test fixture
must expire independently within a bounded time; retain targeted evidence if
cleanup cannot be confirmed. A shell-end timestamp is not host-tool
completion; only the caller can observe the returned tool call.

同 tool Stop 依涵蓋 child 的當次 binding、bounded test 與 owner cleanup 契約，
可在 cleanup 後才返回；跨 tool Preserve 才需要 child 存活時 host 返回。
已證實的 return-live capability 在 route／tool／mode 與相關環境不變時可沿用；
普通 app edit 或 HEAD 變更不構成失效。每次 resource binding、readiness 與
Stop evidence 仍須依當次 owner contract 核對。route 改變時依 disposition
重新評估契約，完整即可採用。同 route 的 host-return 被 child 卡住或 owner／
Stop 契約失效，才使對應能力待 targeted 驗證；app readiness／downstream 失敗
只需處理該次資源。timeout 先查原因，未知原因只將可能受影響的能力列為待查；
若有尚未清理的 binding，先 reconcile，不以未涵蓋失敗 route 的泛稱契約覆蓋。
只有 return-live 未知，且診斷 fixture 有合法 owner、獨立 bounded lifetime 與
Stop 時，才做 bounded 診斷，確認 caller 收到完整 tool result 時 child 尚活著，
並核對後續 OS exit。診斷不提供正式 workload 的 owner 或 Stop authority；
正式契約若仍缺這兩項，須取得適用契約，否則 block/handoff。fixture 的期限
不能當成 production Stop authority，shell timeout 也不是 detachment。

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

區分後續 recovery 與失敗中的原始 Launch。record 遺失、過時或 membership 無法
驗證，且沒有其他有效 owned binding 時，後續 recovery 應有限返回 `unresolved`。
原始 Launch 保留的 current-run OS handles 仍可作為清理該 candidate 的精確
authority；不能只因 publication 或 readiness 失敗就捨棄它們。

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
