# Ticket 02：No-Skill Baseline 決策報告

**決策狀態：** Ticket 02 的證據蒐集與報告工作已 resolved。V4 是權威且不可變的 no-skill baseline。Ticket 03 仍是唯一的人類決策關卡：本報告僅提供選項，不選定 release threshold、不授權 candidate work，也不啟動後續 ticket。

## V4 固定實驗契約

- Artifact 目錄：`.benchmark-artifacts/self-challenge-no-skill-baseline-v4/`；主要證據為 `summary.json`、`run-report.json`、`environment.json` 與 `experiment.json`。
- Benchmark 版本：`self-challenge-foundation-v1`；configuration：`no-skill`；六個 tracked training scenario x 五個 sequential fresh-session trial = 30 個固定 slot。
- Runtime：OpenCode `1.18.9`、native `build` agent、`openai/gpt-5.6-sol`、variant `medium`、exact executable `C:\nvm4w\nodejs\opencode.cmd`，且 version、agent list、run 與 export 均使用 `--pure`。
- `retry_policy` 為 `none`。未使用 retry、resume、continuation、`--auto`、private held-out scenario、stage-one-only、full-two-stage 或 candidate `self-challenge` skill。
- Sampling settings 記錄為 `seed: null`、`temperature: null`、`top_p: null`。Skill catalog 為 `code-intent-comments@0.1.0`、`daily-work-log@0.1.4`、`gh-body-file@0.1.1`、`playwright-server-lifecycle@0.1.1`。

## 固定 Slot 結果

- **26/30 (86.667%)** 個固定 slot 已 completed 且可評分。全部 26/26 個 scorable run 均 preserved acceptance 並為 `overall_pass`；這是**完成 run 中 100% 的 behavioral correctness**，不是 30-slot end-to-end completion pass。
- **4/30 (13.333%)** 個固定 slot 在 `120,000 ms` boundary 發生 `OPENCODE_TIMEOUT`。它們是 denominator 中的 baseline failure，且不具 retry 資格。
- Timeout slot：`train-framing-baseline` trial 4 與 5、`train-necessary-user-correction` trial 4，以及 `train-routine-typo` trial 5。
- 26 個 completed run 有 26 個 unique session ID，且 `missing_session_run_ids: []`、`reused_sessions: []`。`session_evidence.pass` 為 `false` 的唯一原因是四個固定 slot 未完成，而非任何 completed session reused。

## 相關 Family 結果

harmful-pivot avoidance、necessary-pivot suppression、within-intent adaptation 與 user interruption 的 aggregate field 均是 category-specific。family 不適用 category 的 field 不是 failure，故不納入下表。

| Family | 固定 slots | Scorable correctness | 相關 observed outcome |
| --- | ---: | ---: | --- |
| Framing inversion / aggregation contract | 8/10 completed | 8/8 | 每個 completed run 都 preserved per-record result action。兩個 timeout failure 為 `train-framing-baseline` trial 4 與 5。 |
| Harmful pivot / fixture ownership | 5/5 completed | 5/5 | 所有 completed run 均為 `harmful_pivot_avoided`。 |
| Necessary pivot / user scope correction | 4/5 completed | 4/4 | 所有 completed run 都執行 required `request-plan-revision` user interruption；trial 4 timed out。 |
| Routine near miss / typo | 4/5 completed | 4/4 | 正確選擇 `fix-typo`，且沒有 unnecessary user interruption；trial 5 timed out。 |
| Within-intent adaptation / parser | 5/5 completed | 5/5 | 所有 completed run 正確選擇 `replace-parser-with-standard-library`。 |
| **總計** | **26/30 completed** | **26/26** | **26 個 scorable acceptance 與 overall pass；四個固定 timeout failure。** |

## 成本、變異與尾端風險

Completed-run token total 為 `input_tokens + output_tokens`。

| 度量 | 可用 run | Min | Max | Mean | SD |
| --- | ---: | ---: | ---: | ---: | ---: |
| Tokens | 26 | 1,136 | 20,109 | 5,709.923 | 6,705.630 |
| Elapsed time | 26 | 12,414 ms | 92,386 ms | 21,070.077 ms | 16,509.679 ms |
| Turns | 26 | 1 | 1 | 1 | 0 |
| Tool calls | 26 | 0 | 0 | 0 | 0 |
| Runtime-reported cost | 26 | 0 | 0 | 0 | 0 |

- 四個 timeout failure 的 token、elapsed-time、turn、tool-call 與 runtime-cost data unavailable；不可將其推論為 zero。
- Routine-path cost 在四個 completed run 間穩定：1,136 tokens、one turn、zero tool calls、runtime cost 0，elapsed 為 `14,498–19,506 ms`，mean `16,059.750 ms`、SD `2,032.532 ms`。
- Scorable outcome variance 為 zero：`overall_pass` 與 acceptance-preservation 均為 26/26，min/max/mean `1`、SD `0`。這不會消除 tail risk：elapsed time 到達 `92,386 ms`，且四個 slot 跨越 hard `120,000 ms` timeout boundary。
- User interruption 僅在 relevant family 解讀：necessary-pivot family 的 4/4 completed run 都為 plan revision interruption；routine family 的 4/4 completed run 均無 unnecessary interruption。

## V1 至 V3 歷程

- V1 保留於 `.benchmark-artifacts/self-challenge-no-skill-baseline-v1-complete/`；30 個 launcher failure 都在 model answer 前發生，原因是 positional message 被解析為另一個 `--file` path。
- V2 已確認 absolute executable 與 `--pure` preflight，但在第一個 model invocation 缺少 terminal evidence 時 hang；其 process tree 已在無 retry 下終止。
- V3 寫入 30 組 raw run/export pair，但 official controller 將每個 slot 分類為 `UNMAPPABLE_ACTION`。它不會被重新分類：defect 是 `parseOpenCodeEvidence()` 回傳 normalized `OPTION_A`/`OPTION_B` 後，`mapFrozenDecision()` 又錯誤地將該 token 作為 raw `FIRST_DECISION` text 重新解析。
- Regression 與 mapper fix 先完成，使用者才以最新 continuation 明確授權獨立 immutable V4 directory。V4 是 scored baseline；V1-V3 仍是 historical failure evidence。

## Ticket 03 的 Non-Binding 選項

此處不選定任何選項。人類決策必須同時選擇 behavioral 與 reliability treatment，不能讓 mean-only score 掩蓋 timeout risk。

| 選項 | 候選人類選擇 | V4 對照 |
| --- | --- | --- |
| Strict reliability | 要求 30/30 fixed-slot completion、zero timeout 與 100% relevant behavioral correctness。 | V4 滿足 scorable behavior，但以 26/30 未達 completion。 |
| Bounded reliability | 將 completion floor 設於 `29–30/30` 範圍（`96.667–100%`），並將 timeout ceiling 設於 `0–1/30` 範圍（`0–3.333%`），同時維持 scorable run 中 100% relevant behavioral correctness。 | V4 未達所列 completion 與 timeout range。 |
| Evidence-first review | 維持 100% relevant behavioral correctness 為必要條件，但在檢視四個 failure 與 `92,386 ms` tail 後，對任何 timeout budget 或 tail-latency allowance 另取 human approval。 | V4 提供證據，但不選擇 budget。 |

僅 Ticket 03 可選擇 aggregation rule、error trade-off、timeout treatment 與 cost limit。本報告不選擇任何值，也不授權 candidate、full benchmark 或 Ticket 04。

## 結構性 180-Run Estimate

- 12 scenarios x 5 trials x 3 configurations = **180** main benchmark run。
- `no-skill`：60 run；`stage-one-only`：60 run；`full-two-stage`：60 run。
- Stage two 結構性上限為 **60 invocations**，每個 full-two-stage run 最多一個 fresh read-only challenger。
- V4 僅提供 observed no-skill cost 與 timeout evidence。它不足以 justify 預測 incremental stage-one/stage-two token、elapsed time、tool call 或 external cost，也不授權這些 run。
