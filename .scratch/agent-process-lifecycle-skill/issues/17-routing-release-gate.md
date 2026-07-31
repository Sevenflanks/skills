# 17, 執行 routing release gate

**What to build:** 依已實作的 deterministic routing release gate，在 observed environment parity 下比較 `current` 與 `candidate`。Candidate 未達 thresholds 或 evidence 不完整時 block。Gate 只記錄 routing evidence，不授權 Ticket 18 publication。

**Blocked by:** 10，保持候選版本未列出

**Status:** ready-for-agent

## Implementation Contract

- [ ] 使用已安裝的 OpenCode，記錄 raw observed version；不 allow-list 或 reject 任何 version。一次 gate 內所有 phase 使用完全相同 observed environment。歷史 OpenCode `1.18.5` evidence 仍是有效 historical evidence。
- [ ] 只載入兩個 variants，`current` 與 `candidate`，且直接讀取各自 `SKILL.md` frontmatter。Candidate exact model-facing description 固定，gate 不得調整。
- [ ] Calibration 使用 workers `1`、`2`、`4`，兩個 probe prompts，各 variant 每個 probe 一次 valid。只依 completeness/parity 選最高 complete parity worker，不看 trigger outcomes；沒有 complete parity worker 就停止。
- [ ] Fixed base 使用 selected worker，固定為 `current + candidate x 16 prompts x 3 valid = 96`。Invalid attempts 保留但排除，96 是 immutable aggregate denominator。
- [ ] Candidate positive aggregate `>=95%`；positive `3/3` pass、`2/3` targeted、`<=1/3` block。
- [ ] Candidate negative aggregate `<=` 同 run current comparator；negative `3/3` block、`2/3` targeted、`<=1/3` 不擴大。每個 candidate negative false trigger 必須有 zero non-skill tool uses，並完成 raw stdout reparse/hash verification。
- [ ] Targeted 只對授權 prompt 執行，追加 exactly `7` candidate trials，使 total `10`；positive `>=9/10`、negative `<=3/10`。Targeted 不改變 aggregate 或 96 denominator。
- [ ] current/candidate 使用相同 worker、independent fixtures、raw streams、completeness 與 execution parity。任何 phase shape、reference manifest、environment parity、hash 或 raw evidence 失敗都停止。
- [ ] Evidence tree 完整包含 `calibration-w1/`、`calibration-w2/`、`calibration-w4/`、`worker-calibration.json`、`base/`、`base-decision/decision.json`、`base-decision/report.md`、`targeted/<prompt>/`、`final-decision/decision.json` 與 `final-decision/report.md`。
- [ ] 使用 runner 的 `--phase`、benchmark-relative `--output-dir` 與 `--reference-manifest`，以及 evaluator 的 `calibrate --gate-root`、`evaluate --gate-root --stage base|final`。不得使用 stale `--evidence`。
- [ ] Exit code `0` pass、`1` block、`2` invalid evidence/protocol error、`3` targeted required。Calibration 無 complete parity、required evidence 缺漏或 false-trigger safety proof 不成立時停止。

## Completion Boundary

- [ ] Code/protocol contract complete，可由 tests 與文件驗證。
- [ ] Paid/model execution evidence pending，在實際 gate run 完成前不得勾選 execution pass 或宣稱 publication ready。
- [ ] Ticket 18/publication remains separate。Ticket 17 pass 只代表 routing gate evidence 通過，不授權 publication、catalog、marketplace 或其他 Ticket 18 行動。
