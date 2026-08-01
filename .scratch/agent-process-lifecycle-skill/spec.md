# Agent Process Lifecycle 1.0.0 規格

Status: ready-for-agent

## Problem Statement

Agent 啟動的本機程序可能在 initiating tool call 返回、逾時或中止後繼續存活。這些程序可能是 listener、GUI、watcher、background worker、有限時間 detached job，或意外留下的 wrapper、zombie 與不明 owner 資源。若沒有清楚的 lifecycle ownership，Agent 可能把前景命令誤當成安全的背景程序、重複啟動已有服務、回收外部 owner 的程序，或在 PID、名稱、port 等不足以證明 identity 的情況下終止錯誤資源。

現行 `playwright-server-lifecycle` 的責任與 browser QA 混在一起，觸發描述又以 Playwright 和 listener 類型為中心。這使非 browser 的 lifecycle 問題不易被識別，也可能讓同步 command、已由 framework 或 runtime 完整管理的資源誤觸發。另一方面，Windows one-shot PowerShell 無法跨 tool call 保留 live process handle，讓 self-managed fallback 必須有明確的 identity、record、Job 與 finalization 契約，否則安全做法只能是 launch 前 blocked 或 handoff。

本規格的目的，是定義一個責任單一、Windows 可驗證執行、其他平台安全退讓的 lifecycle skill。它不負責 downstream workload 的成功判定，也不負責 Browser QA policy。

## Solution

以 `agent-process-lifecycle` `1.0.0` 直接、全有或全無地取代 `playwright-server-lifecycle`。發布後只存在一個 model-invoked skill，不保留 alias、stub、deprecated shell、parent、child 或新舊名稱並行發布。既有安裝升級時必須直接以新 skill 取代舊 skill，不得保留兩者共存期。

Skill 以 lifecycle-decision routing 為入口。當 Agent 造成的本機 OS process 可能跨越 initiating tool call，或需要處理 owner、start、reuse、preserve、terminate、handoff、cleanup 或 reconciliation 決策時，skill 才介入。同步等到 exit 才返回的 command、owner 與完整 lifecycle contract 已清楚且只是在觀察或使用 external／runtime-managed resource 的任務，不應觸發 lifecycle execution。

Windows 上，skill 先做一次 task-level、reasoning-only entry check，再依序選取第一個可正向證明合約的 execution tier：verified managed lifecycle、verified external launcher、Windows self-managed helper，或 blocked／handoff。這些 tier 不競速，也不在上一 tier 尚未完成 Stop、Preserve、handoff 或 unresolved reconciliation 前 fall through。七類 minimum outcomes 是結果責任，不是每次都要逐項執行的 sequential gates。

`1.0.0` 官方 compatibility 只支援 Windows。Non-Windows 不執行 lifecycle，不做 OS inspection，不執行 lifecycle shell call，也不提供 Linux、macOS 或其他平台 mechanics。它只能做 bounded owner classification。辨識到 managed 或 external owner 時交付 handoff，無法辨識時在 launch 前 blocked，並交付完整 payload。此行為由兩個 prompt-level checks 驗證，不宣稱 non-Windows runtime support。

## User Stories

1. 作為 Agent，我想在本機 process 可能跨越 initiating tool call 時得到 lifecycle routing，才能避免把長時間前景命令誤當成安全背景工作。
2. 作為 Agent，我想以 lifecycle ownership 而不是 process 類型、port 或預估執行時間判斷適用範圍，才能一致處理 listener、GUI、watcher、worker 與 detached job。
3. 作為 Agent，我想在同步 command 會等到 exit 才返回時不載入 lifecycle execution，才能避免不必要的 audit、probe 與 context 成本。
4. 作為 Agent，我想在只觀察或使用 owner 已清楚的 external 或 runtime-managed resource 時退出 lifecycle flow，才能避免誤觸發。
5. 作為 Agent，我想在 owner 必須判斷但不能直接管理的情境交付責任導向 handoff，才能讓真正的 owner 接手後續工作。
6. 作為 Agent，我想把 user、IDE、framework、Docker、Kubernetes、Windows Service 或其他 runtime owner 與 Agent-owned process 分開，才能避免把外部資源納入 current-run cleanup。
7. 作為 Agent，我想在 Windows 上先選 verified managed lifecycle，才能以既有且可驗證的 owner contract 完成更多 lifecycle outcomes，而不重建底層 OS 證據。
8. 作為 Agent，我想在 managed tier 不合格時選 verified external launcher，才能使用具備 detachment、stdio、observation 與 stop contract 的既有 owner。
9. 作為 Agent，我想只在前兩個 tier 不合格且 final disposition 已成立時使用 self-managed helper，才能避免先啟動再補 ownership 或 cleanup 責任。
10. 作為 Agent，我想在任何 tier 都無法證明 detachment 或 ownership 時於 launch 前 blocked 或 handoff，才能避免不安全的自動啟動。
11. 作為 Agent，我想使用第一個 viable tier，而不是先排除所有較低 tier，才能降低 discovery 成本並保持決策可預測。
12. 作為 Agent，我想在 tier 失敗後先完成 reconciliation、Stop、Preserve、handoff 或 unresolved 判定，才能避免多個 tier 同時留下資源。
13. 作為 Agent，我想讓 caller 提供 workload-specific readiness signal 與 deadline，才能由實際 workload 定義可用，而不是用 spawn、process alive、fixed sleep 或 port occupied 冒充 ready。
14. 作為 downstream caller，我想保留自己的 readiness 語意，才能讓 HTTP、window、首次成功編譯、job state 或其他資源使用正確的可用判定。
15. 作為 downstream caller，我不想自己撰寫輪詢 choreography，才能由 lifecycle flow 在需要時執行單一 bounded signal 或 owner event/status。
16. 作為 Agent，我想在 launch 前明確選擇 Stop 或 Preserve，才能在 process 啟動前就知道後續責任如何完成。
17. 作為 current-run owner，我想用 Stop 搭配 identity-bound final disposition，才能只對本次可證明擁有的資源執行終止。
18. 作為需要 keep-running 的使用者，我想用 Preserve 指定 later-cleanup owner 與交付契約，才能保留程序而不誤稱 cleanup 已完成。
19. 作為 handoff recipient，我想收到 live binding、run record、stdio、readiness、later owner 與 Stop 方法，才能在責任轉移後安全收尾。
20. 作為 Agent，我想每次 launch 取得 fresh run ID、handle 或 owner binding，才能避免跨 launch 重用 PID、port、handle 或 run ID。
21. 作為 Agent，我想在 managed path 不做額外 OS inspection 或 lifecycle shell call，才能讓已驗證 owner 的 happy path 保持低成本。
22. 作為 Agent，我想在 Windows self-managed happy path 只呼叫 Launch 與 Finalize，才能避免 status、poll、retry、kill 或第三個 lifecycle action 演變成通用 process manager。
23. 作為 Windows caller，我想用 Launch 一次完成 detached launch、stdio redirect、最小 record 與 bounded readiness，才能避免 caller 分散保存關鍵 identity。
24. 作為 Windows caller，我想用 Finalize 接受 Stop 或 Preserve，才能在同一個 public action 中完成 revalidation、handoff 或 bounded termination。
25. 作為 self-managed owner，我想讓 helper 隱藏 Job、ACL、atomic record、PID identity 與 retained handle 複雜度，才能透過兩個深模組 public actions 使用安全 lifecycle。
26. 作為 self-managed owner，我想讓 helper 建立 fresh、exclusive、受目前使用者 ACL 保護且不可重導的 local record，才能拒絕 stale、concurrent、symlink 或 reparse path。
27. 作為 self-managed owner，我想讓 record 只保存 finalization 所需的最小資料，才能跨 invocation 重建 authority 而不保存可任意重跑的 script body。
28. 作為 self-managed owner，我想讓 run record 綁定 schema、run ID、Job、root identity、stdio、readiness 與 disposition，才能在 Finalize 時 fail closed。
29. 作為 self-managed owner，我想讓 root process 以 suspended 狀態完成 stdio isolation、Job assignment 與 atomic binding 後才 resume，才能避免 child 在 ownership 未建立前裸奔。
30. 作為 self-managed owner，我想讓 workload 不繼承 Job handle，才能避免 production process 取得不應交付的 termination authority。
31. 作為 self-managed owner，我想在 readiness、record write、nested Job assignment 或 stdio allowlist 失敗時同一次 Launch fail closed 並 cleanup，才能避免產生看似成功的 record。
32. 作為 self-managed owner，我想在 Finalize 使用同一個 retained Job handle 完成 query、graceful wait、必要的 forced termination 與 empty-job wait，才能避免 validation-to-termination 的 PID reuse race。
33. 作為 self-managed owner，我想在 PID reuse、record mismatch、Job 不存在、membership 不明或清空無法確認時回報 unresolved 或 handoff，才能拒絕 PID、name、port-only kill。
34. 作為 self-managed owner，我想讓 graceful stop 是可選且 bounded 的 caller action，才能在失敗或逾時時安全進入 forced-only path，而不依賴未保存的 graceful command。
35. 作為 preserve owner，我想讓 Preserve 重新驗證 ownership 但不終止 process，才能可信更新 later owner 並交付日後 Stop 方法。
36. 作為 Agent，我想在 caller 的 downstream finalization 失敗後仍繼續 lifecycle cleanup，才能將 resource result 與 workload result 分開。
37. 作為 downstream caller，我想 lifecycle callback 不覆寫我的 task 或 QA 結果，才能並列呈現兩種結果而不混淆責任。
38. 作為 lifecycle caller，我想在 happy path 收到 tier、binding、stdio、readiness、final disposition 與 evidence paths，才能快速判斷結果。
39. 作為 lifecycle caller，我想在 failure、blocked、preserve、handoff 或 unresolved 時收到 failure kind、cleanup result、evidence、later owner 與未解決原因，才能採取下一步。
40. 作為 non-Windows 使用者，我想在無 owner 時於 launch 前收到 blocked 結果，才能避免 skill 臆造平台 mechanics。
41. 作為 non-Windows 使用者，我想在已辨識 owner 時收到 classification 與 handoff，才能由正確 owner 接手而不讓 skill 執行 lifecycle。
42. 作為 non-Windows reviewer，我想確認兩個行為案例都沒有 OS inspection、launch、termination 或 lifecycle shell call，才能確認官方 compatibility 沒有被暗中擴張。
43. 作為維護者，我想讓 task-local fact bundle 在 repo、worktree、HEAD、working directory、launch config、environment、launcher、wrapper、execution tool、argument mode、owner contract、owner state、requested decision、actual observation、previous failure 或 freshness 改變時失效，才能避免沿用過期分類。
44. 作為維護者，我想以事件式 invalidation 取代每個 command 的 lifecycle audit，才能在安全訊號出現時重做 reasoning-only entry check，而不把每個 command 都變成 OS 掃描。
45. 作為維護者，我想在 excluded path 不建立 fact bundle，才能避免非適用任務留下虛假的 lifecycle facts。
46. 作為維護者，我想在未知 wrapper 的 semantics 影響本次分類時才讀取一次定義，才能避免因所有 script 理論上可能 spawn child 而全面檢查。
47. 作為維護者，我想以 progressive disclosure 在 branch decision site 載入 Windows helper reference，才能讓一般 routing context 不承擔完整 implementation contract。
48. 作為維護者，我想只在 escalation trigger 出現時載入 failure evidence reference，才能讓 happy path 不被冗長 failure dossier 淹沒。
49. 作為維護者，我想保留 ownership、stdio、readiness、observation、shutdown、cleanup、preserve、handoff 與 callback 的 lifecycle contract，才能讓不同 workload 共用同一個責任核心。
50. 作為維護者，我想移除而非搬移 Browser QA 的 completed、passed、blocking severity、screenshot、console、network 與 browser close policy，才能保持 lifecycle-only responsibility。
51. 作為 Browser QA caller，我想自行負責 browser、page 與其他 downstream resource 的關閉，才能避免 lifecycle skill 越界成為 Browser QA owner。
52. 作為 reviewer，我想看到 current 與 candidate 在同一 observed environment 的完整 comparator evidence，才能區分 routing 改善與 runtime safety。
53. 作為 reviewer，我想看到 valid trials、raw streams、fixture isolation 與 completeness evidence，才能避免 invalid attempts 被誤算成 false negative。
54. 作為 reviewer，我想以固定三次 base matrix 判斷 aggregate，才能避免 targeted rerun 改變 denominator。
55. 作為 reviewer，我想只在不一致或距離門檻一個 trial 的 prompt 上擴大至十次，才能以有限成本處理邊界案例。
56. 作為 reviewer，我想讓 candidate near-miss aggregate 不差於 current comparator，才能避免泛化 description 以 recall 名義增加誤觸發。
57. 作為發布維護者，我想讓 routing、runtime、responsibility boundary 與 publication gates 全部通過後才發布，才能阻止只通過結構驗證的半成品。
58. 作為發布維護者，我想一次同步主指令、README、evals、兩份 references、production Windows helper artifacts、root catalog、root docs 與 marketplace metadata，才能避免 published inventory 漂移。
59. 作為發布維護者，我想讓 `npm run validate` 只負責 structural consistency，才能把它與 routing、runtime safety、responsibility boundary gate 分開報告。
60. 作為 downstream reviewer，我想知道 abrupt host crash 與 same-user malicious tamper 是明確 non-guarantees，才能避免把 feasibility prototype 或 local integrity record 誤讀成完整安全保證。
61. 作為 detached finite job 的 caller，我想在 job 自然完成時驗證 exit、result 與沒有殘留，且只在取消、逾時或失去控制時 termination，才能避免把正常 completion 誤當成 cleanup failure。

## Implementation Decisions

1. **替換與版本。** 直接以 `agent-process-lifecycle` `1.0.0` 替換 `playwright-server-lifecycle`。不得保留 alias、stub、parent、child、deprecated compatibility shell 或雙重發布。版本、名稱與 metadata 必須一致。
2. **責任邊界。** Skill 是 Agent-caused local OS process lifecycle decision 的單一 coordinator，涵蓋跨 initiating tool call 的 ownership classification、tier selection、stdio isolation、bounded readiness、event-driven observation、shutdown、cleanup、preserve、handoff、reconciliation 與 callback。實際 lifecycle owner 可是 verified framework、external launcher、Windows self-managed helper 或 handoff recipient。Detached finite job 自然完成時驗證 exit、result 與沒有殘留，只有取消、逾時或失去控制時才 termination。Skill 不是 generic process manager，也不決定 downstream workload 是否成功。
3. **適用與排除。** Agent-owned local process、detached finite job、current-run preserve 與事後殘留 reconciliation 屬於範圍。同步 command、owner 與完整 contract 已清楚且只是在使用或觀察的 external／framework／runtime-managed resource 屬於 near-miss。需要判斷責任的 external resource 仍可觸發分類與 handoff。這個 near-miss exclusion 必須反映在 model-facing description 中。
4. **Model-facing description。** Description 必須使用以下精確文字：`Use when lifecycle-decision routing is needed for an Agent-caused local OS process: a foreground local command may hang or outlive the initiating tool call, a lingering, zombie, or unclear-owner local process needs cleanup or reconciliation, or the task explicitly requests a lifecycle decision for an Agent-started or managed current-run binding. On Windows, select the first viable execution tier and handle readiness, Stop, Preserve, handoff, or reconciliation. On non-Windows, classify an Agent-caused local process only to hand off or block before launch; do not perform lifecycle execution. Do not use for a command that remains synchronous until normal exit, regardless of duration. Do not load this skill merely to classify, Preserve, observe, check status, or use a resource when the prompt already identifies a framework, IDE, Kubernetes, Docker, Windows Service, CI, or other external or runtime owner and states its complete lifecycle contract; follow that owner's contract directly.`
5. **Entry check 與 reuse。** Metadata routing 後，只在第一次 candidate long-lived launch 前做 task-level reasoning-only entry check。不要逐 command audit、PID／port probe、廣泛 OS scan 或 continuous polling。Fact bundle 只在同一 task 的相關 repo、worktree、HEAD、working directory、launch config、environment、launcher、wrapper、execution tool、argument mode、launch behavior、owner identity、owner contract、owner state、requested decision 與 freshness 均未改變且非 unknown 或 stale 時重用。Excluded path 不建立 fact bundle。
6. **Event-driven invalidation。** repo、worktree、working directory、HEAD、相關 config 或 environment 改變，launcher、wrapper、execution tool、argument mode 或 launch behavior 改變，新增 lifecycle decision，owner identity、contract 或 state 改變，exit、crash、timeout、session interruption、previous failure、freshness 不明，或實際觀察推翻原判斷時，讓 bundle 立即失效。下一個相關 lifecycle decision 前重做 entry check。Caller 不負責輪詢 choreography。
7. **平台策略。** `1.0.0` 只承諾 Windows compatibility，只有 Windows 進入 execution tier。Non-Windows 只做 bounded owner classification，不做 OS inspection、lifecycle shell call、launch 或 termination；辨識 owner 就 handoff，否則 launch 前 blocked。Non-Windows handoff payload 必須包含 platform、requested lifecycle need、identified owner 或 contract gap、明確 no launch／termination、缺少的 safety evidence、至少一個不含 platform command 的可行替代方案、next owner 與 unresolved items。
8. **Windows tier hierarchy。** 依序選第一個 viable tier：verified repo／framework managed lifecycle、verified external launcher、Windows self-managed detached wrapper、blocked／handoff。前兩層須有現行 mode/config 的可驗證 owner contract，且能在該 operation 產生 fresh current-run scoped handle 或 binding。Self-managed 只在前兩層不合格時使用。不可並行 race 或以 fallthrough 取代 reconciliation。
9. **Minimum outcomes。** 每個可執行 tier 對 ownership binding、stdio 不再持有 initiating call、需要時 bounded readiness、可觀察 state、Stop 或 Preserve disposition、cleanup 或 handoff、lifecycle callback 逐項提供 owner handled、not applicable 或 escalated 的結果。這些是結果責任，不是每次 launch 都要逐項執行的 gates。Managed path 可一次滿足多項並 short-circuit。
10. **Stop 與 Preserve。** Launch 前必須決定 Stop 或 Preserve。Stop 必須有可執行的 identity-bound final disposition。Preserve 必須先有 later-cleanup owner 與交付契約，成功後交付 fresh live binding、record、stdio、readiness 與日後 Stop 方法。兩者都無法成立時 blocked／handoff。Termination 必須有 live ownership proof，不能以 launch 前已有 live binding 作為必要條件。
11. **Readiness 與 observation。** Caller 提供 workload-specific readiness signal 與 deadline。Helper 只 bounded 執行 caller 選定的 check，不內建 HTTP、port、window、compiler 或 job 規則。Observation 採 event-driven checkpoints，優先在 readiness、首次依賴使用、shutdown／handoff 與錯誤時確認。只有 correctness invariant、明確監看需求或 failure signal 才增加 observation。
12. **Managed 與 external path。** Verified managed path 零額外 OS inspection 與 lifecycle shell calls。Verified external launcher 使用其正式 lifecycle interface，不重建 PID dossier。Scoped handle、run binding 與 contract evidence 可在 task 內重用，但每次 launch 必須有 fresh binding。
13. **Windows helper。** Production helper 是 Windows-only、最後 fallback 的深模組，隱藏 Job、ACL、atomic record、PID identity、live root validation 與 retained Job handle 複雜度。它只提供 `Launch` 與 `Finalize` 兩個 public lifecycle actions。不得新增 `status`、`poll`、`retry`、`kill`、`cleanup` 或第三個 lifecycle action。
14. **Launch。** Caller 提供 executable、argument array、working directory、stdout／stderr paths、workload-specific readiness check 與 deadline。`Launch` 先以 fresh、exclusive、受目前 Windows user ACL 保護且不可重導的 path 建立 `preparing` record，再產生 cryptographically random run ID 與唯一 `Local\` named Job。Root process 以 suspended 狀態完成 stdio isolation、Job assignment 與 recoverable binding 的 atomic update 後才 resume；workload 不得繼承 Job handle。Readiness 完成後再 atomic 更新最小 human-readable JSON run record。Launch 未能安全完成 assignment、allowlist、readiness 或 record write 時，必須同一次 invocation fail closed 並 cleanup；cleanup 不完整就回報 unresolved。
15. **Run record。** Record 只保存 schema version、run ID、Job name、record state、normalized executable、arguments、working directory identity、root PID、creation time、image identity、stdio paths、readiness identity、deadline、result、timestamp、requested disposition 與 Preserve 後的 later owner。PID 與 creation time 只作 instance validation，不作 termination authority。Record 不保存 graceful-stop command。既有 path、concurrent Launch、symlink 或 reparse redirection、schema／binding／identity mismatch 都必須拒絕或 fail closed。
16. **Finalize。** `Finalize` 接受 `Stop` 或 `Preserve`。Stop 可接受 caller 當下提供且 bounded 的 owner-specific graceful action，最多執行一次。未提供、失敗或逾時時可進入 forced-only path。Finalize 必須在相同 Windows session 與相容 security context 中 reopen named Job，使用同一 live root process handle 驗證 PID instance、creation time、image identity 與 Job membership，並保留同一 Job handle 直到 query、graceful wait、必要的 `TerminateJobObject` 與 empty-job wait 結束。Preserve 重新驗證 ownership，atomic 更新 later owner，不終止 process。
17. **Fail closed 與非保證。** Record mismatch、Job 不存在、root instance 不符、membership 無法證明、reopen／query 失敗、forced wait 無法確認清空、wrapper exit 或 daemonize 導致 ownership transfer 時，不得退回 PID、name、port-only kill，結果為 unresolved／handoff。不得使用 `KILL_ON_JOB_CLOSE`。接受 Launch host 在 recoverable record atomic publish 前 abrupt crash 可能留下沒有完整 record 的 suspended process。也不保證能抵禦同一 Windows user security context 下可改寫 record 並建立同名 object 的惡意程式。這兩項必須在 callback、instruction 與 acceptance report 明確揭露。
18. **Callback。** Launch 與 Finalize 都回傳 machine-readable result。Happy path 至少回報 action、run ID、tier、binding、stdio、readiness、final disposition 與 evidence paths。Failure、blocked、preserve、handoff 與 unresolved 額外回報 failure kind、cleanup attempt／result、unresolved reason 與 later owner。Lifecycle result 與 downstream result 分開，callback 不增加第三次 shell call。
19. **Failure 與 handoff。** Ownership ambiguity、readiness failure、owner conflict、unexpected exit、wrapper ambiguity、shutdown timeout、identity mismatch、resource residual 或責任轉移才展開 targeted evidence。無法安全管理時，停止自動 launch，交付能承擔後續 ownership 的責任方或回報 unresolved。Unresolved 是有效且安全的 terminal outcome，不得被包裝成 clean completion。
20. **Progressive disclosure。** Main instructions 依 applicability、platform gate、Windows tier、selected-branch reference、pre-launch Stop／Preserve、execution、Finalize、failure／handoff、contrastive examples、reference index 排列。Windows helper reference 只在選定 self-managed branch 後、pre-launch validation 與 `Launch`／`Finalize` 前載入。Failure and handoff reference 只在 escalation trigger 出現後、diagnostic、reconciliation 或 handoff 前載入。
21. **Browser QA responsibility。** Revised skill 完全移除且不搬移 Browser QA 的 `completed`／`passed`、blocking／non-blocking errors、URL／screen／accessibility evidence、screenshot、console、page、network verdict 與 browser close sequencing。Caller 負責 browser、page 與 downstream resource。Playwright `webServer` 只可作 verified framework owner 的 lifecycle 例子，不再作 Browser QA guidance。
22. **Publishing inventory。** All-or-nothing replacement 必須同步 main instructions、skill README、eval metadata、Windows helper reference、failure and handoff reference、production Windows helper artifacts、root README、root catalog、marketplace metadata 與相關文件清單。舊名稱必須從 catalog 與 marketplace 移除。production helper 在完整 acceptance contract 通過前保持 unavailable，不得以 prototype 取代 production artifact。此規格不新增 changelog、tag 或其他 release requirement。

## Testing Decisions

測試只驗外部行為與責任結果，不測試文件內部排版、私有 helper 分解或 prototype 是否被直接複製。四個 user-confirmed highest external seams 如下：

1. **Model routing。** 使用固定且不含候選 skill name 的 positive 與 near-miss prompts，驗證 model-facing description 是否在 lifecycle decision 情境觸發，並在同步 command，以及 owner 與 lifecycle contract 已清楚且任務僅觀察或使用 external／framework／runtime resource 時避免誤觸發。Release gate 只比較兩個直接從 `SKILL.md` frontmatter 載入的 variants，`current` 與 `candidate`；candidate 的 exact model-facing description 固定，不得由 gate 調整。使用已安裝的 OpenCode，記錄 raw observed version，不 allow-list 或 reject version；同一 gate 的所有 phase 必須 exact same observed environment。Calibration 固定使用 workers 1、2、4、兩個 probe prompts，各一筆 valid，依 completeness/parity 選最高 complete parity worker，不看 trigger outcomes，無 complete parity 就停止。Fixed base 為 `current + candidate x 16 prompts x 3 valid = 96`，96 是 immutable aggregate denominator，invalid attempts 保留但排除。Positive aggregate 必須至少 95%；positive 3/3 pass、2/3 targeted、<=1/3 block。Candidate near-miss aggregate 不得高於同 run current comparator；negative 3/3 block、2/3 targeted、<=1/3 不擴大。Targeted 對授權 prompt 追加 exactly 7 candidate trials，使 total 10，positive 至少 9/10、negative 至多 3/10，且不改變 aggregate。每個 candidate negative false trigger 都必須 zero non-skill tool uses，並完成 raw stdout reparse/hash verification。Routing evidence 必須保留 independent fixture isolation、raw streams、completeness、observed environment parity、reference manifest 與 current/candidate comparator parity。Exit code 0/1/2/3 分別表示 pass/block/invalid evidence or protocol error/targeted required；缺少 required evidence 或 parity 即停止。
2. **Model-visible lifecycle decisions。** 以 model 行為確認 task-level reasoning-only entry check、event-driven invalidation、first viable tier、Stop／Preserve before launch、no race／fallthrough before reconciliation、minimum outcomes 作為責任結果，以及 failure、handoff、unresolved 與 callback payload。另以兩個 non-Windows prompt-level cases 驗證無 owner 時 launch 前 blocked，及可辨識 owner 時 classification／handoff。兩題都必須確認 zero OS inspection、launch、termination、lifecycle shell calls，沒有臆造 platform mechanics，並確認完整 handoff payload。這兩題不是 non-Windows runtime verification。
3. **Windows `Launch`／`Finalize` runtime behavior。** Production helper acceptance 必須逐項通過，不接受 aggregate waiver 或 human waiver。測試 fresh PowerShell invocations 之間的 Job reopen 與 process 存活、外層 Job 下的 nested assignment、stdio isolation、bounded readiness、readiness failure cleanup、graceful Stop、forced Stop、root 與 children 的 scoped termination、unrelated sentinel 保留、fresh exclusive path、atomic create／replace、ACL、redirection rejection、malformed／stale／mismatch record、PID reuse、missing Job、membership mismatch、inaccessible Job、same session／security context、workload 不繼承 Job handle、root 提前退出的 unresolved／handoff 與 Preserve 後的 later Stop。Graceful path 不得使用 forced termination；每個 Stop 或 failure-cleanup 情境結束後，fixture process、named Job 與 temporary artifact 必須全部清空。Preserve 情境不要求清空，改為驗證 handoff owner 與 live binding 仍有效。測試也必須確認沒有 `KILL_ON_JOB_CLOSE`、PID／name／port-only kill、broad scan、常態 polling 或第三 lifecycle action。Acceptance report 分開列出 prototype feasibility facts、production contract checks、abrupt host crash non-guarantee 與 same-user malicious tamper non-guarantee。Prototype evidence 不得被當作 production acceptance。
4. **Repository publication consistency。** 驗證 replacement inventory 的名稱、版本與內容一致，舊 skill 從 catalog 與 marketplace 消失，新 skill 的 main instructions、README、evals、兩份 references、production helper artifacts、root catalog、root docs 與 marketplace metadata 均存在且互相一致。`npm run validate` 只作 structural consistency check，不能代替前三個 seam 的 routing、runtime safety 或 responsibility boundary gates。Publication seam 只確認必要 behavioral evidence 已存在且通過，不重新計算 routing 或 runtime 結果。

Trigger benchmark 的新 gate 只使用 current 與 candidate 的固定 96-trial base matrix，並以 bounded worker calibration 選定 worker。Evidence tree 固定為 `calibration-w1/`、`calibration-w2/`、`calibration-w4/`、`worker-calibration.json`、`base/`、`base-decision/decision.json` 與 `report.md`、`targeted/<prompt>/`、`final-decision/decision.json` 與 `report.md`。Runner 使用 `--phase`、benchmark-relative `--output-dir`、phase-authorized `--reference-manifest`；evaluator 使用 `calibrate --gate-root` 與 `evaluate --gate-root --stage base|final`，不使用 stale `--evidence`。既有三 variant、144 valid trials 的結果顯示 current positive 100.0%、near-miss false trigger 54.2%，原地泛化舊名稱為 95.8%／83.3%，neutral name 為 100.0%／87.5%。這些是 meaningful historical context，不是新兩 variant gate，也不是 runtime safety 或 production acceptance。Invalid attempts 不得算入 trigger rate。Ticket 17 只記錄 routing gate evidence；Ticket 18/publication 仍分離，Ticket 17 pass 不授權 publication。

Prior art 以既有 lifecycle regressions、owner classification、readiness、cleanup、handoff、callback 與 repository catalog consistency 的外部行為測試為準。測試應沿用這些類型的觀察方式，但不延續已退休的 Browser QA assertions，也不以私有實作細節作為穩定測試 seam。

每個 existing eval 都必須逐案轉成 lifecycle-only assertions 或明確 retired，不得原樣保留 Browser QA responsibility。Replacement coverage 至少包含 generic GUI、watcher、detached finite background job、managed owner、runtime handoff、Windows helper，以及前述兩個 non-Windows blocked／owner-handoff prompt cases。

## Out of Scope

- 保留、兼容或同時發布 `playwright-server-lifecycle`，包括 alias、redirect、stub、parent、child 與 deprecated shell。
- 建立 generic process manager、跨 workload 的 persistence schema 或額外治理 subsystem。
- Linux、macOS 或其他 non-Windows 的 lifecycle execution、self-managed mechanics、commands 或 dedicated reference。
- Browser QA policy、browser `completed`／`passed` reporting、blocking severity、screenshots、console、network、accessibility evidence、browser close sequencing 或新的 Browser QA owner。
- 由 lifecycle skill 判定 downstream workload、browser 驗證或 task 的整體成功。
- Caller 自行編排輪詢 choreography，或新增 status、poll、retry、kill、cleanup 等 helper action。
- 以 PID、name、port、fixed sleep、tool timeout 或 process alive 單獨證明 ownership、detachment、readiness 或 termination authority。
- 在沒有 reconciliation、handoff 或 unresolved 判定前同時嘗試多個 execution tier。
- 將 prototype working code、prototype scenario 或 prototype feasibility evidence 直接視為 production helper 或 production acceptance。
- 解決 abrupt host crash 前的 record publish gap，或抵禦同一 Windows user security context 下的惡意 record／named object tamper。
- 新增 release changelog、tag 或其他未決定的發布流程要求。

## Further Notes

本規格是 completed Wayfinder map 與 resolved tickets 的決策完整交付物，供 `/to-tickets` 拆分實作。它不等同 production implementation，也不授權直接搬用 prototype。Production helper 在完整 Windows acceptance contract 通過前必須保持 unavailable；若 host、caller 或 owner contract 不符合條件，安全結果就是 launch 前 blocked、handoff 或 unresolved。

所有 lifecycle callback 都應將 resource result 與 downstream result 分開。`Preserve` 代表責任轉移與交付，不代表 external owner，也不代表 cleanup 完成。`unresolved` 是明確的安全終端狀態，reviewer 不得因沒有殘留或最終 command 成功就把 responsibility-boundary violation 視為可接受。

發布前的 inventory 必須採 atomically replacement，並以 scoped diff 審查只移除舊入口、加入新入口及其決定的 references、evals、helper artifacts 與 catalog metadata。`npm run validate` 的成功只表示結構一致，不能單獨表示 skill 已滿足 routing、runtime safety、responsibility boundary 或 Windows helper acceptance。
