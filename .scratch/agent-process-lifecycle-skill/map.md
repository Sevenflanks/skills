# 提升 Agent 長時間 Process Lifecycle Skill 的觸及率與安全性

## Destination

產出一份將 `playwright-server-lifecycle` 直接 replacement 為 `agent-process-lifecycle` 的決策完整規格，明確決定適用範圍、啟動策略層級、責任邊界、trigger description 與 eval 覆蓋，讓後續 Agent 可直接實作並驗證；本 map 不包含實作。

## Notes

- 本 map 只解決規格決策，不直接修改或發布 skill。
- 每個 session 應依 ticket 性質使用 `grilling`、`domain-modeling`、`prototype`、`skill-creator` 與 `playwright-server-lifecycle`。
- 以 Agent 記憶中已驗證的 Java/Tomcat、Electron、Nuxt/Vite、visual companion 與 foreground HTTP server 事故作為 runtime evidence。
- 所有 child ticket 建立時保持 open 且 unclaimed。

## Decisions so far

- [定義 lifecycle skill 的適用邊界](issues/01-define-lifecycle-skill-boundary.md) — 以可驗證 lifecycle ownership 與是否跨越 initiating tool call 為主界線；Windows 可直接管理 Agent-owned 本機 OS process，non-Windows 僅 bounded 分類並 handoff／blocked。
- [建立 generic 與 near-miss trigger 基準](issues/02-establish-generic-and-near-miss-trigger-baseline.md) — 144 個 valid trials 中，現況、原地泛化與 neutral-name 泛化的 positive/false-trigger 分別為 100.0%/54.2%、95.8%/83.3%、100.0%/87.5%；name 影響僅一筆 trial，generic description 的 precision 成本才是主要訊號。
- [定義 long-lived process 的啟動與 ownership 策略階層](issues/03-define-long-lived-process-launch-and-ownership-strategy-hierarchy.md) — Windows execution 依序採 verified repo/framework、external launcher、自管 detached wrapper、blocked/handoff；managed path 零額外 OS inspection，self-managed happy path 最多兩次 lifecycle call，只有異常或責任轉移才升級完整證據。
- [決定泛化後的 skill 架構](issues/04-decide-generalized-skill-architecture.md) — 將既有 skill 直接 replacement 為單一 `agent-process-lifecycle`，以 task-level lifecycle-decision routing、一次性 entry check 與事件式 invalidation 控制誤觸發，不保留 parent、alias 或雙重發布。
- [劃分共用 process lifecycle 與 browser QA 責任](issues/05-separate-shared-process-lifecycle-and-browser-qa-responsibilities.md) — Revised skill 只管理 lifecycle，移除且不搬移 Browser QA policy；managed path 零額外 OS inspection，self-managed happy path 最多兩次 lifecycle call，failure 才升級 targeted evidence。
- [決定 Windows self-managed lifecycle helper 的最小契約](issues/08-decide-windows-self-managed-lifecycle-helper-contract.md) — 納入 Windows-only fallback helper，只提供 Launch／Finalize；以受 ACL 保護的 atomic JSON binding、live root identity 與 retained named-Job handle 管理 Stop／Preserve，接受 record 發布前 abrupt-crash gap。
- [設計修訂後的 skill instruction 骨架](issues/06-design-revised-skill-instruction-skeleton.md) — 以 lifecycle-decision description 與 execution-ordered 主流程提高觸及率，inline minimum outcomes／safety guards，採 Windows first viable execution tier、Stop／Preserve、責任導向 handoff 與 Windows self-managed Launch／Finalize；non-Windows 僅 bounded 分類／handoff。
- [定義修訂版的驗收與發布契約](issues/07-define-revised-acceptance-and-publishing-contract.md) — 以 zero-tolerance safety／責任邊界、分層 routing gates、四個 public seams、Windows helper 全檢與 `1.0.0` all-or-nothing replacement 定義後續實作門檻。
- [定義 non-Windows self-managed guidance 深度](issues/09-define-non-windows-self-managed-guidance-depth.md) — `1.0.0` 官方只支援 Windows；non-Windows 不執行 lifecycle，只能 bounded 分類並 handoff 或在 launch 前 blocked，另以兩個 prompt-level behavior cases 驗證零 OS／lifecycle calls 與完整 payload。

## Not yet specified

## Out of scope

- 在本 map 內直接修改、重新命名、拆分或發布 skill。
- 建立通用 process manager subsystem。
- 在本 map 內建立或統一 Browser QA reporting skill；若未來有實證需求，另開 effort。
- 支援 Linux／macOS lifecycle execution 或 self-managed mechanics；若未來要支援，另開 Wayfinder effort。
- 修復與本 lifecycle 問題無關的 runtime bug。
