# 生產驗收證據：Windows helper

## 文件狀態與範圍

這是 Ticket 15 已封存的 production acceptance evidence。本文只把本次工作階段實際觀察到的 runtime、validation 與 review 結果列為 production PASS，並將歷史 prototype 可行性與 non-guarantees 分開記錄。

固定比較基準是 `ba1d626`，commit subject 為 `docs(agent-process-lifecycle): 完成 ticket 14`。

目前 candidate tree 身分與狀態如下：

* branch：`feature/agent-process-lifecycle`
* HEAD：`ba1d626`
* 已修改：`.scratch/agent-process-lifecycle-skill/candidate/tests/windows-helper-ticket-11.test.mjs`、`.scratch/agent-process-lifecycle-skill/candidate/windows-helper/Invoke-AgentProcessLifecycle.ps1`
* 本次 intended change 的檔案：`.scratch/agent-process-lifecycle-skill/candidate/windows-helper/Invoke-AgentProcessLifecycle.ps1`、`.scratch/agent-process-lifecycle-skill/candidate/tests/windows-helper-ticket-11.test.mjs`、`.scratch/agent-process-lifecycle-skill/candidate/tests/windows-helper-ticket-15.test.mjs`、`.scratch/agent-process-lifecycle-skill/candidate/agent-process-lifecycle/references/windows-self-managed.md`、`.scratch/agent-process-lifecycle-skill/candidate/evidence/windows-helper-acceptance.md`、`.scratch/agent-process-lifecycle-skill/issues/15-preserve-helper-acceptance.md`
* `.omo/` 是明確排除的 unrelated continuation metadata，不屬於 intended change
* `JobHandleHolder.ps1` 與 `ba1d626` 相同，未修改

## 本次執行環境與確定結果

環境版本是本次 current run 以唯讀版本命令觀察到的值：

| 項目 | 觀察值 |
| --- | --- |
| OS surface | Windows，Ticket 11 至 15 測試均為 Windows-only 或 Windows helper surface |
| Node | `v24.15.0` |
| npm | `11.12.1` |
| PowerShell | `PowerShell 7.6.4` |
| 固定 base | `ba1d626` |

以下是 current run 已提供的 exact command/result/count evidence。以下區塊均預期直接從 worktree root 貼到 PowerShell 7 執行；本次沒有重新執行，結果沿用既有紀錄。

**PowerShell parser：PASS，helper 與 holder parser 均 PASS。**

```powershell
$files = @(
    '.scratch/agent-process-lifecycle-skill/candidate/windows-helper/Invoke-AgentProcessLifecycle.ps1'
    '.scratch/agent-process-lifecycle-skill/candidate/windows-helper/JobHandleHolder.ps1'
)
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -ne 0) { throw $errors }
}
```

**Node syntax：PASS，6/6。**

```powershell
$files = @(
    'windows-helper-ticket-11.test.mjs'
    'windows-helper-ticket-12.test.mjs'
    'windows-helper-ticket-13.test.mjs'
    'windows-helper-ticket-14.test.mjs'
    'windows-helper-ticket-15.test.mjs'
    'protected-test-fixture.mjs'
)
foreach ($file in $files) {
    node --check (Join-Path '.scratch/agent-process-lifecycle-skill/candidate/tests' $file)
    if ($LASTEXITCODE -ne 0) { throw "node --check failed: $file" }
}
```

**Ticket 15 targeted runtime：PASS，10 top-level、Node 15 including nested，`156.659s`。**

```powershell
node --test .scratch/agent-process-lifecycle-skill/candidate/tests/windows-helper-ticket-15.test.mjs
```

**Serialized runtime：PASS，top-level 40/40、Node 45 including nested，pass 45／fail 0，`377.040s`。**

```powershell
node --test --test-concurrency=1 `
  .scratch/agent-process-lifecycle-skill/candidate/tests/windows-helper-ticket-11.test.mjs `
  .scratch/agent-process-lifecycle-skill/candidate/tests/windows-helper-ticket-12.test.mjs `
  .scratch/agent-process-lifecycle-skill/candidate/tests/windows-helper-ticket-13.test.mjs `
  .scratch/agent-process-lifecycle-skill/candidate/tests/windows-helper-ticket-14.test.mjs `
  .scratch/agent-process-lifecycle-skill/candidate/tests/windows-helper-ticket-15.test.mjs
```

**Skill catalog validation：PASS，exit 0。**

```powershell
npm run validate
```

**Protected fixture residue：PASS，fixture root empty。**

```powershell
$root = Join-Path $env:USERPROFILE '.agent-process-lifecycle\Tests'
if (@(Get-ChildItem -LiteralPath $root -Force).Count -ne 0) {
    throw 'protected fixture root is not empty'
}
```

**Volume-root lifecycle residue：PASS，`C:\` 下的 `agent-process-lifecycle-*`、`.omo` 與 `.sisyphus` residue 為 0。**

```powershell
$volumeRoot = [IO.Path]::GetPathRoot((Resolve-Path '.').Path)
$entries = @(
    Get-ChildItem -LiteralPath $volumeRoot -Force |
        Where-Object { $_.Name -like 'agent-process-lifecycle-*' -or $_.Name -in @('.omo', '.sisyphus') }
)
if ($entries.Count -ne 0) {
    throw "Unexpected volume-root residue: $($entries.FullName -join ', ')"
}
```

**Holder comparison：PASS，unchanged from `ba1d626`。**

```powershell
$env:GIT_MASTER = '1'
git diff --exit-code ba1d626 -- .scratch/agent-process-lifecycle-skill/candidate/windows-helper/JobHandleHolder.ps1
```

`same-session same-SID` 的 outer Job 覆蓋是實際成功的 current run production surface。測試使用 instrumented helper，把 numeric Job handle value 作為 data 加入 workload argument；觀察到 workload 與 caller SID 和 session 相同、launched root 確實 nested，且 workload 無法把該 numeric value 當成可 query 的 inherited Job handle 使用。這不是 numeric value invisible 的證明，也不是 alternate account 測試。

`access denied` 覆蓋是 injected negative coverage。測試以 injected `Win32Exception` error 5 模擬 authority query 失敗，確認 Preserve 與 later Stop 都回報 `job-unverifiable`、不執行 graceful action、不嘗試 termination、record 保持不變且 workload 與 holder 仍存活。不得把它描述成 alternate account、不同使用者或真實 ACL 身分切換測試。

## 生產驗收矩陣

下表是 production checks。Ticket 11 至 14 的 rows 是本次 serialized inventory 中重用的既有覆蓋，Ticket 15 rows 是本次新增或擴充的覆蓋。

| 來源 | Production check | Current result |
| --- | --- | --- |
| Ticket 11 | fresh invocation 的 Launch 與 Finalize，跨 PowerShell invocation 交付 binding | PASS，重用 Ticket 11 row |
| Ticket 11 | bounded readiness deadline 與 graceful callback deadline | PASS，重用 Ticket 11 rows |
| Ticket 12 | fail-closed Launch、readiness failure cleanup、fresh/exclusive protected record | PASS，重用 Ticket 12 rows |
| Ticket 12 | atomic create/replace、ACL/reparse rejection、workload Job-handle noninheritance | PASS，重用 Ticket 12 rows |
| Ticket 13 | valid-authority graceful/forced owned-tree Stop、root/child cleanup | PASS，重用 Ticket 13 rows |
| Ticket 13 | unrelated sentinel preservation、無 broad termination 或其他 prohibited broad termination | PASS，重用 Ticket 13 rows |
| Ticket 14 | malformed/stale/schema/binding/identity/missing Job/root/holder/event/query/membership/access-denied structured rejection | PASS，重用 Ticket 14 rows；no side effects |
| Ticket 15 | fresh Preserve invocation 記錄 requested later owner，保留 live binding；matching owner 與合法 transition | PASS，Ticket 15-specific |
| Ticket 15 | nested assignment under same-session same-SID outer Job，且 workload numeric parent Job handle query 失敗 | PASS，Ticket 15-specific；實際 outer Job coverage |
| Ticket 15 | Preserve handoff 與 later Stop，包含 Preserve 後的 graceful Stop | PASS，Ticket 15-specific |
| Ticket 15 | forced later Stop 移除 owned tree 並保留 unrelated sentinel | PASS，Ticket 15-specific |
| Ticket 15 | early root exit 後只保留可證明的 owned child；deterministic PID reuse safety model 拒絕 live unrelated identity mismatch | PASS，Ticket 15-specific；這是 deterministic production modelling，不是真實 Windows PID recycling |
| Ticket 15 | Preserve graceful input 與 Stop owner rejection | PASS，Ticket 15-specific |
| Ticket 15 | malformed/stale/mismatch/missing/membership/inaccessible handoff authority negative checks | PASS，Ticket 15-specific；inaccessible 部分為 injected access denied |
| Ticket 15 | publication failure 的 original unchanged、artifact residue、unknown outcomes | PASS，Ticket 15-specific；`preserved-with-artifact-residue` 是 lifecycle `unresolved`，但 final disposition 為 `preserved`，且有 valid `later_owner`、`handoff_published` 與含 `record_path` 的安全 `stop_method` |
| Ticket 15 | publication residue evidence 與 cleanup/live handoff proof | PASS，Ticket 15-specific；residue scenario 在 assertion 後由 fresh later Stop 成功消費 returned `stop_method`，並移除 exact record-scoped artifact、record、root、holder 與 Job |
| Ticket 15 | prohibited mechanisms，例如 name kill、PID-only kill、port-only lookup、broad scan；protected fixture scope、ACL/reparse-safe fixture、root cleanup | PASS，Ticket 15-specific source/parser coverage；protected fixture root empty |

Production matrix 的 `PASS` 只表示 current run 的 test evidence 已觀察到。它不等於 review 已完成，也不擴張成未執行的 alternate-account coverage。

## 公開 helper 與 reference 的契約對照

`JobHandleHolder.ps1` 不是 model-facing reference，且不是本 acceptance 的行為契約來源。Parity 比較的是 model-facing fields 與 constraints：只允許 `Launch`/`Finalize`，`Stop`/`Preserve` dispositions，owner inputs，帶 `record_path` 的安全 `stop_method`，downstream separation，rejection semantics，同一 session/context 的 binding，serialization，以及兩項 non-guarantees。current run 的 holder comparison 只確認 `JobHandleHolder.ps1` 與 `ba1d626` unchanged；真正的 model-facing reference 保持 dormant，直到 Ticket 16 才啟用。沒有以 instrumented test helper 冒充 production reference。

## 歷史 prototype 可行性事實

本節不是 production acceptance。它只保留 Harness.ps1 的四個歷史 prototype scenario feasibility facts，不能用來補足 production matrix：

1. `cross-invocation-graceful-and-stdio`：跨 invocation 的 graceful lifecycle 與 stdio separation 可行。
2. `forced-job-tree-with-unrelated-sentinel`：forced Job-tree cleanup 可行，且 unrelated sentinel 可保留。
3. `readiness-failure-cleans-in-launch`：readiness failure 可在 Launch 內完成 cleanup。
4. `tampered-record-fails-closed`：record creation-time mismatch 可 fail closed。

上述四點是 Harness.ps1 prototype feasibility facts。它們不是獨立的 production PASS，也不代表曾執行真實 PID recycling、alternate-account ACL 或 host crash 測試。

## 不保證事項

以下兩項是明確的 non-guarantees，不是 failure，也不是待補成 PASS 的測試結果：

1. 如果 host 在 atomic publication 完成前突然 crash，這份 acceptance evidence 不保證 record publication 一定可判定為 unchanged、residue 或 unknown，也不保證自動完成 cleanup。重新啟動後仍需依可取得的 record、artifact 與 process identity 進行 reconciliation。
2. 同一使用者的惡意 record 或 named object tamper 不在本次保證範圍。ACL 與 owner checks 可限制一般非授權內容，但本 evidence 不宣稱能防止同一 user 惡意修改 record、替換 named object 或偽造 identity claims。

## 審查收據（Review receipts）

**狀態：PASS。**

固定 review base 為 `ba1d626`，兩軸於 2026-07-30 對目前 Ticket 15 candidate diff 完成複審：

* Standards review：PASS，session `ses_04e46a539ffemsWhvoHi7xbC30`。Nonblocking observations 是 rejection result 的 parameter data clump，以及 Launch／Finalize record-scoped artifact enumeration 的重複形狀；未因這些 judgement calls 擴張本 ticket 的 refactor scope。
* Spec review：PASS，session `ses_04e46a22affeB35iTh8iK2mJGR`。確認 Preserve mixed outcome、later Stop exact artifact cleanup、post-Stop cleanup failure 的 machine-readable unresolved result、reference parity、prototype identifiers 與 acceptance scope 均符合 Ticket 15／Issue 08 契約。
