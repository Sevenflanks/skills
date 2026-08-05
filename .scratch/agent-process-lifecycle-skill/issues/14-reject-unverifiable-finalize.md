# 14 — 拒絕無法驗證的 Finalize authority

**What to build:** 專門處理 Finalize 的 authority rejection：當 saved binding 無法證明 Stop 或 Preserve authority 時，讓 Finalize fail closed，回傳 responsibility-oriented unresolved 或 handoff 與缺少的 evidence，且絕不猜測性 termination。本 ticket 不重做 valid-authority Stop、Launch ownership 或 Preserve implementation。

**Blocked by:** 13, 停止具有效 authority 的 owned process tree

**Status:** completed

- [x] Finalize 對 malformed、stale、schema-mismatched、binding-mismatched、identity-mismatched 或 missing record 都回傳 rejection。
- [x] Finalize 對 missing ownership object、failed reopen 或 query、不相容 session 或 security context，以及無法驗證的 root membership 都回傳 rejection。
- [x] rejected Finalize 絕不以 PID、name、port 或 process-alive evidence 作為 termination authority，也不執行 guessed kill。
- [x] 每個 rejection 都回傳 failure kind、cleanup attempt 與 result、unresolved reason、evidence，並在責任需轉移時提供 later owner。
- [x] public result 將 unresolved 標示為安全的 terminal lifecycle outcome，不得偽裝成 clean completion。
