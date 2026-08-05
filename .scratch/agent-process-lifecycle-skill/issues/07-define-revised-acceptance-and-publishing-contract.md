# 定義修訂版的驗收與發布契約

Type: grilling
Status: resolved
Blocked by: 04, 05, 06

## Question

修訂規格必須定義哪些 runtime safety、generic positive-trigger、near-miss negative-trigger、相容性與 responsibility-boundary 驗收條件？後續實作應同步哪些 README、eval、catalog、marketplace、版本與 `npm run validate` 契約？本 ticket 只決定契約，不執行發布。

## Answer

採用下列 all-or-nothing acceptance 與 publishing contract。這是直接 replacement 的規格，不是本 ticket 的實作或發布；prototype facts 不能替代 production checks，且 abrupt-host-crash 與 same-user tamper 明確維持 non-guarantees。

### Release blockers and public seams

- Deterministic runtime safety 與 responsibility boundary 是 zero-tolerance release blockers。任何 responsibility-boundary violation 都 block release，即使 cleanup 最終成功。
- Acceptance tests 只驗四個 public seams：selection、model-visible lifecycle behavior、Windows `Launch`／`Finalize` behavior、repository publication consistency。不建立 Browser QA policy，也不擴張成 generic process manager。
- Ticket 08 的每一項 production Windows helper safety check 都必須通過，不接受 aggregate waiver 或 human waiver。Prototype 的正常流程 evidence 另列，不得拿 prototype 四個 scenarios 宣稱 production safety 已通過。
- `npm run validate` 只驗 structural consistency，必須與 routing、runtime safety、responsibility-boundary gates 分開報告，不能代替它們。

### Routing benchmark protocol

Routing protocol 分層執行：ordinary iteration 每個 prompt 先跑 1 次 valid run；release gate 每個 prompt 跑 3 次 valid runs；只有結果不一致，或距離門檻只差 1 trial 的 prompts，才 targeted rerun 至 10 次。Aggregate 只使用每題固定 3 次的 base matrix；追加的 7 次只判定該 prompt gate 並分開報告，不得把補跑題目以較大 denominator 混回 aggregate。Environment 必須 pin，candidate 與 current comparator 在同一 run 比較；保留 independent fixtures、raw streams、completeness evidence，排除 invalid attempts。

Trigger benchmark 的 acceleration 也受同一完整性約束。既有 full evidence 使用 `workers=4`、3 variants、144 trials；release 只比較 current 與 candidate，base 為 96 trials，減少 33%。Iteration 可先跑 candidate-only 一次，targeted rerun 以 prompt selection 限定；bounded smoke 可校準較高 worker count，但候選與 comparator 必須使用相同且記錄的 worker count。不得犧牲 fixture isolation、stream evidence、comparator parity 或 completeness。

Positive gate 為 aggregate `>=95%`。Initial `3/3` 是 desired；`2/3` 擴大至 10 次且必須達成 `>=9/10`；`0/3` 或 `1/3` 直接 block release。

Near-miss candidate aggregate 不得在同一 run 超過 current comparator。`3/3` false trigger 直接 block；`2/3` 擴大至 10 次且必須 `<=3/10`。每一次 false trigger load 都必須在沒有任何 OS inspection、launch、termination 或 lifecycle shell call 的情況下退出。

### Runtime and compatibility coverage

Existing evals 必須逐一轉成 lifecycle-only，或明確 retired。轉換必須保留 lifecycle regressions，移除 Browser QA assertions，並新增 generic GUI、watcher、finite background job、managed owner、runtime handoff 與 Windows helper coverage。`1.0.0` 官方 compatibility 只支援 Windows；non-Windows 只驗兩個 prompt-level behavior cases：無 owner 時 launch 前 blocked，可辨識 owner 時 classification／handoff。兩題都必須 assert zero OS inspection、launch、termination、lifecycle shell calls、invented platform mechanics 與 complete handoff payload；這些是 model-behavior checks，不是 non-Windows runtime verification。

### Publication contract

版本定為 `1.0.0`。只有所有 routing、runtime、responsibility-boundary gates 通過，且 ticket 09 已 resolve 後，才可執行 all-or-nothing replacement。發布時必須 atomically 移除舊名稱，並同步 `SKILL.md`、skill `README.md`、`evals`、`references/windows-self-managed.md`、`references/failure-and-handoff.md`、ticket 08 所要求的 production Windows helper artifact(s)、root `README.md`、`skills.json` 與 marketplace metadata；接著執行 `npm run validate`，最後只提交 scoped diff。不得保留 alias、deprecated stub、dual publication 或其他雙重入口；本契約不新增 release changelog 或 tag requirement。
