# 決定泛化後的 skill 架構

Type: grilling
Status: resolved
Blocked by: 01, 02

## Question

根據「定義 lifecycle skill 的適用邊界」與「建立 generic 與 near-miss trigger 基準」的結果，應原地泛化 `playwright-server-lifecycle`、保留舊 skill 並增加 generic parent，或採其他相容架構？各 skill 的責任、觸發邊界與 migration 成本為何？

## Answer

採單一 skill 直接 replacement：將 `playwright-server-lifecycle` rename 為 `agent-process-lifecycle`，並原地泛化其 lifecycle contract。不新增 generic parent、browser child、alias 或 deprecated stub，也不讓新舊名稱同時發布。這個決定以長期責任清晰度優先於一次性的安裝相容成本。

### Architecture and responsibility

- `agent-process-lifecycle` 是唯一 process lifecycle owner，負責 Agent-caused 本機 OS process 在可能跨越 initiating tool call 時的 ownership 分類、launch strategy、readiness、observation、shutdown、cleanup／preserve、handoff 與 callback contract。
- 同步等待 exit 的 command，以及具完整可驗證 owner contract 的 external、framework 或 runtime-managed resource，不由本 skill 直接管理。
- 本 skill 不成為 generic process manager，也不吸收 downstream 工作本身的成功判定。Browser QA 的 `completed`／`passed`、browser evidence 與 lifecycle callback 如何組合，留給「劃分共用 process lifecycle 與 browser QA 責任」決定。
- 不採 parent／child delegation。兩個 metadata owner 會增加競爭觸發、循環或重複 delegation、版本同步與 migration 成本，而現有 trigger baseline 沒有顯示這些成本能換得 recall 增益。

### Trigger contract

Trigger 採 lifecycle-decision gate，不採廣泛 process gate：

- 任務語意顯示 process 可能跨越 initiating call，或需要 owner、start、reuse、preserve、terminate、handoff、cleanup 或 reconciliation 決策時，才載入 skill。
- 同步 command 會等到 exit、owner 已明確且 contract 完整、只是連線或觀察 external service，或 remote／runtime-managed workload 沒有本機 launcher lifecycle 問題時，不觸發。
- Metadata routing 後，只在首次 candidate long-lived launch 前做一次 reasoning-only entry check。不得對每個 command 執行 lifecycle audit，也不得預設做 PID／port probe、廣泛 OS scan 或 continuous polling。
- Unknown wrapper 只有在其 lifecycle semantics 影響本次分類時才讀取定義一次；不因所有 script 理論上都可能 spawn child 而全面展開檢查。

### Task-local reuse and invalidation

Classification 只在同一 task 的 repo／worktree、launch-related config、environment、launcher、wrapper、參數模式與 owner contract 未發生實質變更時重用。下列事件會使結果立即失效，並在下一個相關 lifecycle 決策前重做 reasoning-only entry check：

- repo、worktree、working directory、launch-related config 或 environment 改變。
- launcher、wrapper script、執行工具、參數模式，或 foreground／background／detach／watch／reuse 行為改變。
- 任務新增 start、reuse、preserve、terminate、handoff、cleanup 或 reconciliation 決策。
- owner identity、owner contract 或 owner state 改變，包括 exit、crash、timeout 或 session interruption。
- 實際結果推翻原判斷，例如 initiating call 返回後仍觀察到本機 process 或 resource 存活。

此設計接受一項 residual risk：opaque script 可能靜默 daemonize，且沒有任何後續症狀。完全消除此風險需要 per-command audit，成本不成比例；一旦出現殘留、卡住或 ownership 異常訊號，則由 reconciliation 入口重新納入。

### Migration contract

- 發布時從 catalog 與 marketplace 移除 `playwright-server-lifecycle`，加入 `agent-process-lifecycle`；repo 內 frontmatter、README、eval metadata 與路徑同步更名。
- 既有安裝必須先移除舊 skill，再安裝新 skill。不得把舊 skill 留作 redirect 或 compatibility shell，避免兩份 metadata 同時觸發。
- 精確 version、發布 gate 與驗收矩陣由「定義修訂版的驗收與發布契約」決定。

### Evidence and trade-off

Trigger baseline 中，現況、原地泛化舊名稱與 neutral-name 泛化的 positive／near-miss false-trigger 分別為 `100.0%／54.2%`、`95.8%／83.3%`、`100.0%／87.5%`。Name 差異只影響各一筆 trial，不能證明 rename 可改善 routing；rename 的理由是 generic domain identity 與長期責任清晰度。反之，generic description 的高 false-trigger 顯示不能只靠廣泛 metadata，必須以 lifecycle-decision routing、一次性 entry check 與事件式 invalidation 控制成本與誤觸發。
