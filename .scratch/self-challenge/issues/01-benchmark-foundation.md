# 01 — 建立可執行的分層 benchmark 基礎

**What to build:** 建立一個可重複執行的完整 agent-task transcript benchmark，讓後續能在沒有 candidate skill 的情況下，先客觀評分方向轉折、最終處置、驗收保持與執行成本。

**Blocked by:** None — can start immediately.

**Status:** resolved

**Claimed by:** current OpenCode session on `feature/plan-reflection-skill`

- [x] 每個 scenario 在執行前記錄 authoritative sources、evidence reveal order、confirmed-intent truth、baseline validity、正確 disposition、允許的 next actions、最早禁止的方向性 edit 與外部 acceptance oracle。
- [x] Scenario corpus 涵蓋 harmful pivot、necessary pivot、within-intent adaptation、routine near miss 與 framing inversion，且 training 與 true held-out 依 scenario family 分隔。
- [x] Runner 可分別執行 no-skill、stage-one-only 與 full two-stage 配置，並支援同一 scenario 的重複 trial。
- [x] Scorer 分開產生 process、outcome 與 cost measures，且能辨識 harmful pivot、necessary-pivot suppression、premature edit、不必要 stage two 與超出成本的 transcript。
- [x] 以刻意錯誤與正確的 deterministic transcript fixtures 證明 scorer 不會因流程表面合規就錯判 outcome 成功。
- [x] Benchmark foundation 不包含 candidate skill 文字、runtime helper、production dependency、持久化治理或歷史 session runtime mining。

## Completion

- `npm run test:benchmark`: 26 tests passed.
- `npm run verify:benchmark-held-out`: 36 private held-out runs passed locally; fixtures remain ignored.
- `npm run validate`: repository validation and benchmark tests passed.
- `git diff --check`: passed.
