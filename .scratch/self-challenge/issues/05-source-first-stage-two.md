# 05 — 實作 source-first 的 stage-two 對抗流程

**What to build:** 當 stage one 判定 imminent candidate action 可能影響 confirmed intent 或仍有方向性不確定時，使用同一個 fresh read-only sub-agent 分兩輪重建來源並對抗 candidate，最後產生可執行 verdict。

**Blocked by:** 04 — 實作安靜且低成本的 stage-one self-challenge

**Status:** resolved

**Claimed by:** current implementation session

- [x] Stage two 只在已有 imminent candidate action，且它可能改動 confirmed intent 或決策相關不確定性仍存在時啟動；單靠 repeated candidate changes 不得自動升級。
- [x] 每個 pivot 只建立一個未參與 candidate 形成的 fresh sub-agent，並在 runtime 可強制時設為 read-only；否則只可聲稱未觀察到 write。
- [x] 第一輪只提供 authoritative sources 或 retrieval instructions、problem evidence、constraints 與 non-goals，不揭露 candidate；sub-agent 先重建 baseline、invariants、source conflicts、alternative hypotheses 與 falsification conditions。
- [x] 第二輪向同一 sub-agent 揭露 candidate，要求 steelman 保持與偏離兩邊、指出主 agent 最可能錯在哪裡、命名 protected 或 invalidated invariant，並說明何種 evidence 會改變結論。
- [x] Verdict 依 evidence-first precedence 產生 `MORE_EVIDENCE`、`REPLAN_REQUIRED`、`ADAPT_WITHIN_INTENT` 或 `KEEP_COURSE`，並附可驗證理由與允許的 next action。
- [x] Source precedence 僅在最新且最明確的 user decision 形成唯一 evidence-backed 排序時才視為已解；否則必須回報 unresolved intent conflict。
- [x] Sub-agent 不得 edit、修改 plan、授權 scope change、建立第二個 challenger 或遞迴啟動 `self-challenge`。

## Answer

- Deterministic evidence: `stage-two-protocol.test.mjs` proves a non-empty caller-supplied candidate opens one logically distinct challenger once, keeps it out of caller-controlled round-one fields, preserves authoritative source content, fixes source order and precedence before round two, and runs two sequential `ask()` calls on the same handle.
- Deterministic benchmark evidence: the fixture adapter uses `observed-no-write` plus logical `candidate_former_agent_id` freshness evidence; full transcript tests prove source retrieval, reconstruction, same-challenger attribution, verdict action validation, MORE_EVIDENCE direction-change blocking, and that a process-compliant harmful action still fails outcome. The scorer separately fails observed writes and recursive invocation.
- Verification: focused stage-two tests, `npm run test:benchmark` (69/69), and `npm run validate` (repository validation plus 69/69) passed. No live OpenCode run, live report, or new `.benchmark-artifacts` output was created.
- Initial implementation exploration exposed only ignored, permanently quarantined held-out path and regex-hit metadata. It did not open or use fixture content; no broader zero-access claim is made.
- Ticket 04 V1/V2 training-only evidence and its interpretation remain unchanged.
- Excluded: Ticket 06 failure, bounded-investigation, retry, and reentry policy; Ticket 07 trigger-description optimization; Ticket 08 locked full benchmark and held-out execution; Ticket 09 publication, registry, catalog, and effect claims.
