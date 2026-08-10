# 17, 執行 routing release gate

**What to build:** 依已實作的 deterministic routing release gate，在 observed environment parity 下比較 `current` 與 `candidate`。Candidate 未達 thresholds 或 evidence 不完整時 block。Gate 只記錄 routing evidence，不授權 Ticket 18 publication。

**Blocked by:** 10，保持候選版本未列出

**Status:** completed

## Implementation Contract

- [x] 使用已安裝的 OpenCode，記錄 raw observed version；不 allow-list 或 reject 任何 version。一次 gate 內所有 phase 使用完全相同 observed environment。歷史 OpenCode `1.18.5` evidence 仍是有效 historical evidence。
- [x] 只載入兩個 variants，`current` 與 `candidate`，且直接讀取各自 `SKILL.md` frontmatter。Candidate exact model-facing description 固定，gate 不得調整。
- [x] Calibration 使用 workers `1`、`2`、`4`，兩個 probe prompts，各 variant 每個 probe 一次 valid。只依 completeness/parity 選最高 complete parity worker，不看 trigger outcomes；沒有 complete parity worker 就停止。
- [x] Fixed base 使用 selected worker，固定為 `current + candidate x 16 prompts x 3 valid = 96`。Invalid attempts 保留但排除，96 是 immutable aggregate denominator。
- [x] Candidate positive aggregate `>=95%`；positive `3/3` pass、`2/3` targeted、`<=1/3` block。
- [x] Candidate negative aggregate `<=` 同 run current comparator；negative `3/3` block、`2/3` targeted、`<=1/3` 不擴大。每個 candidate negative false trigger 必須有 zero non-skill tool uses，並完成 raw stdout reparse/hash verification。
- [x] Targeted 只對授權 prompt 執行，追加 exactly `7` candidate trials，使 total `10`；positive `>=9/10`、negative `<=3/10`。Targeted 不改變 aggregate 或 96 denominator。
- [x] current/candidate 使用相同 worker、independent fixtures、raw streams、completeness 與 execution parity。任何 phase shape、reference manifest、environment parity、hash 或 raw evidence 失敗都停止。
- [x] Evidence tree 完整包含 `calibration-w1/`、`calibration-w2/`、`calibration-w4/`、`worker-calibration.json`、`base/`、`base-decision/decision.json`、`base-decision/report.md`、`final-decision/decision.json` 與 `final-decision/report.md`。`required_targeted_prompt_ids=[]`，因此未建立 `targeted/<prompt>/`。
- [x] 使用 runner 的 `--phase`、benchmark-relative `--output-dir` 與 `--reference-manifest`，以及 evaluator 的 `calibrate --gate-root`、`evaluate --gate-root --stage base|final`。不得使用 stale `--evidence`。
- [x] Exit code `0` pass、`1` block、`2` invalid evidence/protocol error、`3` targeted required。Calibration 無 complete parity、required evidence 缺漏或 false-trigger safety proof 不成立時停止。

## Completion Boundary

- [x] Code/protocol contract complete，可由 tests 與文件驗證。
- [x] Paid/model execution evidence complete；final gate outcome 為 `blocked`，未宣稱 execution pass 或 publication ready。
- [x] Ticket 18/publication remains separate。Ticket 17 pass 只代表 routing gate evidence 通過，不授權 publication、catalog、marketplace 或其他 Ticket 18 行動。

## Execution Result

- Gate：`ticket-17-release-gate-20260731T101324Z`
- Observed OpenCode：`1.18.9`
- Selected worker：`4`；calibration workers `1`、`2`、`4` 均 complete 且 parity matched。
- Fixed base：96 valid trials，0 invalid attempts。Current positive `24/24`、negative `22/24`；candidate positive `24/24`、negative `11/24`。
- Final outcome：`blocked`（exit code `1`）。Candidate negative prompts `kubernetes-runtime` 與 `sync-long-command` 均為 `3/3` false triggers。
- Targeted：`required_targeted_prompt_ids=[]`，因此未執行 targeted trials。
- Evidence：calibration 與 base manifests 驗證成功；environment parity matched；false-trigger safety passed；privacy scan 未發現 user-home paths、secrets 或 internal markers。
- Publication：未授權 Ticket 18，candidate 保持未列出。
