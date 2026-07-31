# OpenCode Trigger Baseline

此目錄是 scratch-only、可重現的 deterministic routing release gate，不是新 skill，也不修改 published skill。Gate 只比較兩個從各自 `SKILL.md` frontmatter 直接載入的 variants：

1. `current`：published skill 的現行 name 與 description。
2. `candidate`：候選 skill 的 name 與 description。candidate 的 exact model-facing description 是固定契約，gate 不得調整。

每次執行都使用當下已安裝的 OpenCode，manifest 記錄 raw observed version。一次 gate 內 current、candidate、calibration、base 與 targeted 必須使用完全相同的 observed environment。Gate 不 allow-list 或 reject 任何 OpenCode version。歷史上的 OpenCode `1.18.5` benchmark evidence 仍是有效的 historical evidence，不因版本政策改變而失效。

## Protocol

- `trigger-evals.json` 固定 16 個不含候選 skill name 的 end-user prompts，八個 positive 與八個 near-miss negative。
- 每個 trial 使用獨立 temporary fixture，fixture 只允許 `skill` tool。只有完整、可重解析的 terminal evidence 才是 valid；invalid attempts 必須保留，但排除於 trigger rate 與 aggregate denominator。
- Candidate negative 的每一個 false trigger 必須證明 zero non-skill tool uses，並對 raw stdout 做 reparse 與 hash verification。缺少此證據即停止。
- 每個選取的 variant、prompt、logical run 在 bounded retries 後必須恰有一筆 valid trial。缺漏、多筆 valid trial、environment 或 comparator parity 不一致，都停止，不得產生可接受的 gate decision。
- Candidate 與 current 必須在同一 observed environment、相同 worker count、independent fixtures、raw streams 與 completeness/parity checks 下比較。候選 description、prompt classification、threshold 與 denominator 不得由 gate 調整。

## Calibration And Fixed Base

Calibration 只使用兩個 probe prompts，每個 prompt 每個 variant 一次 valid run，分別以 workers `1`、`2`、`4` 執行。選擇最高的 complete parity worker，只看 completeness 與 parity，不看任何 trigger outcome。若沒有 complete parity worker，立即停止。

Selected worker 用於同一 gate 的 current 與 candidate base，以及必要的 targeted evidence。Fixed base 永遠是 `current + candidate x 16 prompts x 3 valid runs = 96` valid trials。這個 96 是 immutable aggregate denominator。Invalid attempts 仍留在 evidence，但不加入 96，也不算成 false negative 或 false trigger。

## Thresholds And Outcomes

- Candidate positive aggregate 必須 `>=95%`。
- Positive prompt 為 `3/3` 時 pass，`2/3` 時 targeted，`<=1/3` 時 block。
- Candidate negative aggregate 必須 `<=` 同一 run 的 current negative comparator。
- Negative prompt 為 `3/3` false trigger 時 block，`2/3` 時 targeted，`<=1/3` 時不擴大。
- Targeted 僅對獲授權的 prompt 執行，對該 prompt 的 candidate 追加 exactly `7` trials，使該 prompt total 為 `10`。Positive 必須 `>=9/10`，negative 必須 `<=3/10`。Targeted 永遠不改變 fixed base aggregate 或其 96-trial denominator。
- Exit code `0` 表示 pass，`1` 表示 block，`2` 表示 invalid evidence 或 protocol error，`3` 表示需要 targeted evidence。
- Calibration 沒有 complete parity、任何 required phase shape 不符、reference manifest 不符、parity/hash 不符、raw stdout 無法重解析，或 false trigger 使用 non-skill tool 時停止。停止不等於 pass，也不得授權 Ticket 18。

## Commands

以下 command 從 repository root 執行；runner 仍會將 `--output-dir` 與 `--reference-manifest` 解讀為 benchmark directory 內的相對路徑。未執行 paid/model calls 的驗證不應代替 gate evidence。

```powershell
$BenchmarkRoot = ".scratch/agent-process-lifecycle-skill/benchmarks/02-trigger-baseline"
$GateRoot = "results/<gate-root>"
py -3.12 "$BenchmarkRoot/run_trigger_baseline.py" --phase calibration --workers 1 --output-dir "$GateRoot/calibration-w1"
py -3.12 "$BenchmarkRoot/run_trigger_baseline.py" --phase calibration --workers 2 --output-dir "$GateRoot/calibration-w2"
py -3.12 "$BenchmarkRoot/run_trigger_baseline.py" --phase calibration --workers 4 --output-dir "$GateRoot/calibration-w4"
py -3.12 "$BenchmarkRoot/evaluate_routing_release_gate.py" calibrate --gate-root $GateRoot
```

Calibration 選出 worker 後，先從 `worker-calibration.json` 載入 selected worker，再使用該 calibration manifest 作為 fixed-base reference：

```powershell
$Calibration = Get-Content -Raw "$BenchmarkRoot/$GateRoot/worker-calibration.json" | ConvertFrom-Json
$SelectedWorkers = [int]$Calibration.selected.workers
$SelectedCalibrationManifest = "$GateRoot/calibration-w$SelectedWorkers/manifest.json"
py -3.12 "$BenchmarkRoot/run_trigger_baseline.py" --phase fixed-base --workers $SelectedWorkers --output-dir "$GateRoot/base" --reference-manifest $SelectedCalibrationManifest
py -3.12 "$BenchmarkRoot/evaluate_routing_release_gate.py" evaluate --gate-root $GateRoot --stage base
```

若 base 回傳 `3`，對 decision 指定的每個 prompt 各執行一次 targeted command，並以 base manifest 作為 reference：

```powershell
$Calibration = Get-Content -Raw "$BenchmarkRoot/$GateRoot/worker-calibration.json" | ConvertFrom-Json
$SelectedWorkers = [int]$Calibration.selected.workers
py -3.12 "$BenchmarkRoot/run_trigger_baseline.py" --phase targeted --workers $SelectedWorkers --prompt <authorized-prompt> --output-dir "$GateRoot/targeted/<authorized-prompt>" --reference-manifest "$GateRoot/base/manifest.json"
py -3.12 "$BenchmarkRoot/evaluate_routing_release_gate.py" evaluate --gate-root $GateRoot --stage final
```

不得使用過時的 `--evidence` argument。

## Evidence Layout

```text
<gate-root>/
├── calibration-w1/
├── calibration-w2/
├── calibration-w4/
├── worker-calibration.json
├── base/
├── base-decision/
│   ├── decision.json
│   └── report.md
├── targeted/<prompt>/
└── final-decision/
    ├── decision.json
    └── report.md
```

每個 run 的 `manifest.json` 記錄 observed environment、variant frontmatter、selection、worker、reference、completeness、source hashes 與 artifact hashes；`trials.ndjson` 保留所有 attempts，`logs/` 保留 raw stdout/stderr，`aggregate.json` 只在該 phase completeness gate 通過後產生。

## Historical Context And Scope

既有三 variant、144 valid trials 的結果仍保留在規格作為 historical context。那次結果顯示 current positive `100.0%`、near-miss false trigger `54.2%`，原地泛化舊名稱為 `95.8%/83.3%`，neutral name 為 `100.0%/87.5%`。它不是新的兩 variant gate，也不是 runtime safety 或 publication acceptance。

Ticket 17 只記錄 routing release gate evidence。Ticket 18 的 publication、catalog 或 marketplace 更新仍是獨立工作，Ticket 17 pass 不授權、不代表、也不提前完成 Ticket 18。
