# 定義 non-Windows self-managed guidance 深度

Type: grilling
Status: resolved
Blocked by: 07

## Question

在 `agent-process-lifecycle` 僅承諾 managed 與 verified external cross-platform path，且 Windows self-managed 才有 `Launch`／`Finalize` helper 的前提下，non-Windows self-managed fallback 的 guidance 最低必須寫到什麼深度？請決定：最低 non-Windows self-managed guidance 內容、對 compatibility 的明確 promise 與 non-promise、哪些 blocked／handoff evidence 必須交付，以及是否支援任何 non-Windows mechanics。不得在本 ticket 直接實作或發布。

## Answer

本決策明確改寫 Question 中原先的 cross-platform compatibility 前提：`1.0.0` 的官方 compatibility promise 只涵蓋 Windows。Non-Windows 不進入 direct lifecycle execution，也不提供 dedicated reference、Linux／macOS commands 或其他 platform mechanics。

在 non-Windows 上，Agent 只能做 bounded owner classification，不得做 OS inspection、lifecycle shell call 或任何 launch／termination。若能辨識 managed 或 external owner，分類後將責任 handoff 給該 owner，不執行 lifecycle；若無法辨識 owner，必須在 launch 前 blocked。非 Windows 的第一、第二 owner type 僅能作為 handoff 分類，不能視為本 skill 的執行 tier。Main `SKILL.md` 後續加入一個 inline platform gate，並重用規劃中的 `references/failure-and-handoff.md`，不另建 non-Windows reference。

Handoff payload 至少包含：platform 與 requested lifecycle need、identified owner and/or contract gap、explicit no launch/termination statement、missing safety evidence、至少一個可行替代方案、next owner，以及 unresolved items。替代方案可提及已驗證的 repo/framework owner、已驗證的 external launcher、user terminal／IDE ownership，或避免 persistent process，但不得包含 platform commands。

本階段 acceptance 只有兩個可由目前 fixture 執行的 prompt-level behavior cases：

1. Non-Windows、無 owner 的 request 必須在 launch 前 blocked。
2. Non-Windows、可辨識 owner 的 request 必須完成 classification 並 handoff。

兩題都必須 assert zero OS inspection、launch、termination、lifecycle shell calls 與 invented platform mechanics，並 assert complete handoff payload。這些是 model-behavior checks，不是 non-Windows runtime verification。未來 Linux／macOS mechanics 需另開 Wayfinder effort，不屬於本 `1.0.0` destination。
