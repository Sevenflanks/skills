# Self-Challenge Skill

Status: ready-for-agent

## Problem Statement

Agent 在依照已確認意圖實作時，可能因 blocker、失敗測試、review finding、使用者糾正或看似合理的 workaround，迅速把眼前問題翻成新的作法。此時 agent 往往認為自己只是在修正局部錯誤，沒有察覺新作法已改變 scope、驗收條件、核心語意、安全邊界或既定方向。

這種衝動式方向轉折會造成反覆返工、修正鏈不斷延長、已確認決策被靜默推翻，以及最終交付與驗收衝突。現有 code review、debugging 與 adversarial review 流程能審查成品或診斷問題，但沒有一個輕量流程專門在執行中的方向轉折前，要求 agent 先檢查自己是否被當下問題誤導。

## Solution

建立 model-invoked `self-challenge` skill，在 agent 準備因局部證據改變作法時提供兩段式反思。

第一段是短且便宜的可追溯性檢查。Agent 先辨認候選作法可追溯到哪項已確認意圖、會改變哪些承諾，以及若判斷錯誤會造成什麼回頭成本。一般 within-plan 修正到此即可繼續，不建立額外門檻。

第二段只在 agent 已形成即將採取的候選作法，且該作法可能改變已確認意圖或短反思後仍無法確定時啟動。主 agent 建立一個 fresh、read-only sub-agent，先只提供可獨立核對的已確認意圖、目前 plan/ticket、眼前證據、constraints 與 non-goals，讓 sub-agent 從來源重建 baseline、invariants、替代假設與反證條件；第二次提問才揭露主 agent 的候選作法並要求裁決。Sub-agent 以可推翻的保守推定同時 steelman 既有基線與新作法，主動尋找主 agent 可能錯誤的理由，再依 evidence-first precedence 回傳 `KEEP_COURSE`、`ADAPT_WITHIN_INTENT`、`REPLAN_REQUIRED` 或 `MORE_EVIDENCE`。

此流程不新增 approval gate，也不賦予 sub-agent 修改 plan 的權限。只有既有規則本來就要求使用者決策的方向性變更，才會因 `REPLAN_REQUIRED` 停下詢問。

## User Stories

1. As a user, I want an agent to pause before changing an agreed direction, so that a local blocker does not silently rewrite the work I approved.
2. As a user, I want the pause to remain lightweight for ordinary implementation fixes, so that reflection does not become a new approval gate.
3. As a user, I want confirmed intent to include explicit decisions, acceptance criteria, spec/SRS, tickets, plans, ADRs, and confirmed non-goals, so that an agent cannot ignore a commitment merely because it is not in one plan file.
4. As a user, I want intent-source precedence to require a unique evidence-backed ordering, so that stale documents do not override later clarification and ambiguous recency-versus-clarity conflicts are not silently decided by the agent.
5. As a user, I want the skill to recognize tempting phrases such as "just unblock this", "small local fix", or "add a workaround first", so that it can trigger before the agent consciously labels its action as a plan change.
6. As a user, I want review findings that imply different domain grouping, data granularity, ownership, security, compatibility, or acceptance semantics to receive deeper scrutiny, so that a locally attractive fix does not violate the approved behavior.
7. As a user, I want unplanned todos, subsystems, persistence, data sources, validation gates, and recovery paths to be challenged before adoption, so that scope does not expand through implementation convenience.
8. As a user, I want repeated changes of candidate solution to trigger reflection, so that a chain of failed workarounds does not carry the implementation farther from its baseline.
9. As an implementing agent, I want a short first-stage check, so that I can continue immediately when a change is clearly within confirmed intent.
10. As an implementing agent, I want a fresh sub-agent for ambiguous direction changes, so that my current framing is challenged by a context that did not participate in producing the candidate fix.
11. As an implementing agent, I want the sub-agent to independently read authoritative sources, so that a biased summary cannot predetermine the answer.
12. As an implementing agent, I want a small fixed verdict vocabulary, so that I know whether to keep course, adapt within intent, return to decision-making, or gather more evidence.
13. As a user, I want normal successful reflection to stay quiet, so that the agent reports only when reflection changes the planned action or needs my decision.
14. As a skill maintainer, I want realistic trigger and near-miss benchmarks, so that description changes improve invocation without turning every bug or test failure into a deep review.
15. As a skill maintainer, I want evaluation at the full agent transcript seam, so that tests verify observable behavior rather than internal checklist wording.
16. As a skill maintainer, I want the new skill to remain distinct from code review, review-feedback handling, debugging, and challenge-review, so that each workflow keeps one clear responsibility.
17. As an implementing agent, I want stage one to identify a falsifier and a lower-commitment alternative, so that traceability cannot become a ceremony that justifies the first idea.
18. As a user, I want the adversarial sub-agent to reconstruct intent before seeing the proposed pivot, so that the proposal does not anchor the review from its first turn.
19. As a user, I want uncertainty, sub-agent failure, and conflicting intent sources to fail safely without retry loops or silent plan changes, so that reflection cannot become another source of drift.
20. As a skill maintainer, I want balanced harmful-pivot and necessary-pivot scenarios, so that reducing changes is not mistaken for improving decisions.
21. As a skill maintainer, I want release thresholds locked after a no-skill baseline and before tuning, so that acceptance is neither arbitrary nor selected after seeing favorable skill results.

## Implementation Decisions

- Publish a model-invoked skill named `self-challenge` with an initial `0.1.0` version. It becomes stable only after the required behavior and trigger gates pass.
- Use **self-challenge** as the leading concept: an agent questions its own candidate direction before acting, rather than seeking general approval or performing a final review.
- Treat **confirmed intent** as the complete baseline: explicit user decisions, acceptance criteria, spec/SRS, ticket/plan, ADRs, and confirmed non-goals. When sources conflict, the latest and clearest explicit user decision has priority only when the sources form a unique, evidence-backed ordering. If recency and clarity point to different sources or no unique ordering exists, the conflict remains unresolved and the agent must not choose a convenient winner.
- Use a two-stage flow. Stage one is a short traceability reflection. Stage two creates one fresh read-only sub-agent only when the candidate action may change confirmed intent or uncertainty remains.
- Trigger stage one from observable pivot cues instead of requiring the agent to have already noticed a conflict. Cues include blockers, failing evidence, review findings, user corrections, tempting workarounds, unplanned work, changes to semantic boundaries, and repeated changes of candidate solution. A cue starts only the cheap stage-one check; it does not by itself justify stage-two escalation.
- Do not deepen for routine typo fixes, ordinary within-plan debugging, a fallback already authorized by the plan, initial design exploration without a confirmed baseline, or final artifact review.
- Before any direction-changing edit, stage one identifies the triggering evidence, the proposed action, its exact traceability to confirmed intent, the commitment it could alter, one observable fact that would falsify the candidate action, and one alternative that changes fewer commitments. Normal stage-one success remains quiet.
- Escalate to stage two only when an imminent candidate action exists and at least one of these holds: traceability is missing; scope or acceptance may change; a domain/data/ownership/security/compatibility boundary may change; new unauthorized work may be introduced; candidate solutions have repeatedly changed; confirmed-intent sources conflict; or uncertainty remains after stage one. Repeated candidate changes are supporting evidence, not an independent automatic escalation rule.
- Use the same fresh stage-two sub-agent for two sequential prompts. The first prompt contains authoritative intent sources and retrieval methods, current plan/ticket context, the observed problem, evidence, constraints, and non-goals, but not the main agent's candidate action. It requires source-first reconstruction of the baseline, invariants, alternative hypotheses, and falsification conditions. The second prompt reveals the candidate action and asks the sub-agent to evaluate it against that prior reconstruction.
- Keep the stage-two sub-agent fresh and read-only. Fresh means a new agent identity that did not participate in forming the candidate action. Read-only must be enforced by available tool permissions when the runtime supports that boundary; otherwise acceptance can claim only that no write action was observed. The sub-agent may investigate code, tests, history, and documents, but it must not edit files, revise the plan, authorize a scope change, or invoke `self-challenge` recursively.
- Apply a **rebuttable conservative presumption**: confirmed intent is the current best baseline and a deviation carries the burden of evidence. The sub-agent must still identify evidence that invalidates the baseline instead of defending it blindly.
- Require the sub-agent to steelman both the baseline and the proposed deviation, state the strongest case that the main agent is wrong, distinguish implementation/test/environment defects from an invalidated plan assumption, name the invariant protected or invalidated, state what evidence would change its conclusion, and return one verdict with evidence.
- Apply evidence-first precedence before selecting exactly one of four verdicts:
  - If decision-relevant evidence is insufficient or confirmed-intent precedence is unresolved, return `MORE_EVIDENCE` before considering an action disposition.
  - Once evidence is sufficient, use `REPLAN_REQUIRED` when proceeding changes confirmed intent or the baseline requires explicit revision; use `ADAPT_WITHIN_INTENT` when implementation may change without changing user-observable commitments; otherwise use `KEEP_COURSE` when deviation lacks support.
- Define the four verdicts:
  - `KEEP_COURSE`: the proposed direction change is unsupported; solve the issue without changing confirmed intent.
  - `ADAPT_WITHIN_INTENT`: the implementation detail may change without changing confirmed intent.
  - `REPLAN_REQUIRED`: proceeding would change confirmed intent or the baseline itself needs an explicit decision-layer revision.
  - `MORE_EVIDENCE`: evidence is insufficient; define one decision-relevant question, the smallest read-only investigation or test that can answer it, its completion signal, and the scope that investigation must not expand.
- Verdicts do not create new authority. `KEEP_COURSE` and clear `ADAPT_WITHIN_INTENT` results may continue. `MORE_EVIDENCE` prohibits the direction-changing edit until its bounded investigation completes, then runs the evidence-first classification again; if uncertainty remains, use existing user-owned decision rules. `REPLAN_REQUIRED` follows existing user-decision and planning rules.
- Allow at most one stage-two sub-agent for the same combination of confirmed-intent baseline, candidate action, and decision-relevant evidence. Do not retry after timeout, source-access failure, malformed output, or failure to return one verdict. A failed stage two is not evidence for the pivot; fall back to bounded `MORE_EVIDENCE`, then existing user-decision handling if uncertainty cannot be resolved. A new self-challenge cycle is allowed only after decision-relevant evidence or the candidate action materially changes.
- Keep normal output quiet. Report a concise result only when self-challenge changes the action the main agent was about to take; ask the user only when an existing user-owned decision is required.
- Keep responsibility boundaries explicit:
  - `code-review` reviews a completed diff against standards and spec.
  - `receiving-code-review` evaluates external review feedback before implementation.
  - `diagnosing-bugs` builds a feedback loop and finds root cause.
  - `challenge-review` performs a deliberate multi-agent review of a target before finalization.
  - `self-challenge` interrupts one in-progress direction transition before the main agent acts on it.
- Publish the skill using the repository's standard skill metadata, human README, catalog entries, marketplace entry, root README index, and behavioral eval set. Do not add a runtime helper, persistence subsystem, or new production dependency.

## Testing Decisions

- Use the complete agent-task transcript as the primary behavioral seam. Tests may inspect prompts, tool ordering, source retrieval, sub-agent identity and capabilities, public verdict, next action, direction-changing edits, and final acceptance behavior. They must not grade private chain-of-thought or require stage one to emit ceremonial prose on the normal path.
- Label every scenario before execution with authoritative sources, evidence reveal order, confirmed-intent truth, whether the baseline remains valid, the correct disposition, allowed next actions, the earliest prohibited direction-changing edit, and an external acceptance oracle. This prevents graders from rationalizing whichever verdict the agent produced.
- Divide evaluation into three layers:
  1. **Trigger layer**: realistic prompts and long transcripts test whether implicit pivot cues start stage one without making routine debugging, initial design, or final review overtrigger.
  2. **Decision layer**: matched scenarios compare no-skill, stage-one-only, and full two-stage behavior to determine whether the sub-agent adds value beyond self-reflection.
  3. **Outcome and cost layer**: measure whether the final action preserves the correct acceptance behavior and whether benefit is proportional to turns, tokens, tool calls, stage-two invocations, and user interruptions.
- Balance scenario families instead of selecting mostly incorrect deviations:
  - **Harmful pivot**: the baseline remains valid and the tempting candidate would violate confirmed intent.
  - **Necessary pivot**: decision-relevant evidence invalidates the baseline or proves explicit replanning is required.
  - **Within-intent adaptation**: implementation may change while user-observable commitments remain stable.
  - **Routine near miss**: typo, ordinary debugging, authorized fallback, initial exploration, directly verifiable review feedback, or final review should not deepen.
  - **Framing inversion**: identical authoritative sources are paired with opposing main-agent summaries or candidate framings; reconstruction and verdict should follow sources rather than framing.
- Include real-pattern scenario families without using historical sessions as a runtime dependency: fixture-location changes that conflict with ownership/security contracts, unapproved diagnostic snapshots after missing reproduction, review suggestions that alter grouping or aggregation, user corrections that reveal scope mistakes, and repeated workaround changes.
- Stage-one-only evaluation observes whether the agent avoids a prohibited edit, stays within confirmed intent, and avoids unnecessary stage two. It does not claim to observe silent internal reasoning.
- Full two-stage evaluation verifies that one fresh read-only sub-agent is used at most once per unchanged pivot; source-first reconstruction occurs before candidate disclosure; authoritative sources are actually retrieved; no write or recursive self-challenge occurs; evidence-first precedence is followed; and failure or unresolved evidence blocks the direction-changing edit.
- Report process measures separately from outcome measures. Process measures include stage-one trigger recall, routine false escalation, stage-two conditional rate, source retrieval, verdict correctness, premature-edit rate, sub-agent write attempts, recursion, and failure handling. Outcome measures include harmful-pivot avoidance, necessary-pivot suppression, within-intent adaptation correctness, final acceptance preservation, reverted direction-changing edits, and unnecessary user interruption. Cost measures include turns, tokens, tool calls, elapsed time when available, and stage-two invocation count.
- Run repeated stochastic trials and split held-out data by scenario family rather than random paraphrase. Description authors and tuning runs must not use the truly held-out fixtures. Record model, runtime, complete skill catalog, sampling settings, tool availability, and benchmark version so later changes can be compared honestly.
- Establish release thresholds in two steps. First run the no-skill baseline and present outcome variance, error trade-offs, and estimated full benchmark cost to the user. After the user confirms acceptable harmful-pivot, necessary-pivot-suppression, routine-cost, and interruption bounds, record and lock those thresholds before tuning the description or skill body. Relative improvement alone is not sufficient when absolute behavior or cost remains unacceptable.
- Estimate and disclose expected run count, token use, time, and external cost before executing the full layered experiment. Starting the benchmark requires the user's confirmation of that estimate; this is an execution-cost approval, not a new product requirement.
- Limit effect claims to demonstrated evidence. Passing controlled fixtures may support a claim that the skill improved harmful-pivot and restraint proxies in that benchmark. It must not be described as proven to reduce long-term real-world rework without corresponding field evidence.
- Require repository validation to pass after all skill and catalog changes. Structural validation complements but does not replace layered behavior and trigger evidence.
- Preserve benchmark artifacts outside the published skill unless the repository's existing conventions explicitly require them. Published evals contain reusable scenarios and expectations, not transient run output or supposedly unexposed held-out fixtures.

## Acceptance Criteria

- [ ] `self-challenge` is published as a model-invoked skill with complete required metadata and matching catalog/marketplace version.
- [ ] The skill defines the two-stage reflection flow and does not create a mandatory sub-agent or user gate for ordinary within-plan fixes.
- [ ] The description contains observable pivot cues and near-miss boundaries without treating a cue alone as stage-two justification or requiring the agent to have already recognized a plan conflict.
- [ ] Trigger scenarios show no prohibited direction-changing edit before the applicable stage-one disposition or stage-two verdict; routine stage-one-only scenarios remain quiet and avoid unnecessary sub-agents.
- [ ] Stage two uses at most one fresh read-only sub-agent per unchanged pivot and completes source-first reconstruction before the candidate action is disclosed.
- [ ] The sub-agent retrieves authoritative sources, applies the rebuttable conservative presumption without ignoring baseline-invalidating evidence, steelmans both directions, names falsification conditions, and follows evidence-first verdict precedence.
- [ ] `REPLAN_REQUIRED` does not directly modify or authorize modification of confirmed intent.
- [ ] `MORE_EVIDENCE` defines a bounded decision-relevant investigation, prohibits premature direction change, reclassifies after new evidence, and cannot create retry or recursion loops.
- [ ] Sub-agent timeout, source-access failure, malformed output, or missing verdict does not retry, authorize the pivot, or bypass existing user-owned decision rules.
- [ ] Normal `KEEP_COURSE` and clear `ADAPT_WITHIN_INTENT` results do not create unnecessary user interruptions.
- [ ] Behavioral evals contain pre-adjudicated harmful-pivot, necessary-pivot, within-intent, routine near-miss, and framing-inversion families at the complete transcript seam.
- [ ] Layered experiments compare no-skill, stage-one-only, and full two-stage configurations across repeated runs and family-level held-out scenarios.
- [ ] Process, outcome, and cost measures are reported separately; a process-compliant run cannot pass when it suppresses necessary pivots, permits harmful pivots, or exceeds locked cost bounds.
- [ ] The no-skill baseline is completed before skill tuning, benchmark execution cost is disclosed, and user-approved release thresholds are recorded and locked before description or body optimization.
- [ ] Published effect claims do not exceed what the controlled benchmark demonstrates.
- [ ] No runtime helper, persistence subsystem, new dependency, or unrelated existing-skill behavior is introduced.
- [ ] Repository validation passes with all required published-skill metadata synchronized.

## Out of Scope

- Automatically rewriting, approving, or replacing a plan, spec, ticket, ADR, acceptance criterion, or explicit user decision.
- Adding a new universal approval gate before edits or requiring user confirmation for ordinary implementation choices.
- Replacing debugging, code review, review-feedback handling, architecture review, or multi-agent challenge review.
- Running multiple adversarial sub-agents for each pivot.
- Persisting reflection history in a database, adding a state machine, or building a governance/evidence subsystem.
- Automatically mining old sessions during every invocation. Historical sessions are eval seeds, not a runtime dependency.
- Changing existing skills to invoke `self-challenge` unless a later independently approved requirement calls for integration.
- Solving an underlying product bug or changing a project's confirmed intent on behalf of the user.

## Further Notes

- The critical design risk is under-triggering before the agent consciously labels an action as a direction change. Trigger wording should therefore focus on temptation and action cues, not only on explicit conflict vocabulary.
- The opposite risk is turning every blocker into an expensive review. The short first stage and near-miss cases are required to preserve normal implementation flow.
- The name `self-challenge` intentionally emphasizes self-questioning. Its description and body must keep it distinct from the existing `challenge-review` command.
- The repository glossary defines confirmed intent, pivot, self-challenge, and rebuttable conservative presumption; implementation and tests should use those terms consistently.
