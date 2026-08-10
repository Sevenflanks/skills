# 11 — Launch 與 graceful Finalize Stop

**What to build:** 讓 Windows caller 以一次 Launch 啟動一個 detached workload，使用 caller 提供的 bounded readiness，並以一次 public Finalize Stop 完成 valid authority 下的 graceful Stop happy path。caller 取得 machine-readable lifecycle result，且 downstream workload result 維持分離。本 ticket 不處理 Preserve、forced fallback 或 authority failure matrix。

**Blocked by:** 10, 保持候選版本未列出

**Status:** completed

- [x] valid Launch 產生 fresh run binding、隔離 stdio、caller-defined bounded readiness，並回傳 selected tier 與 requested disposition。
- [x] Launch 與 Finalize Stop 由兩個 fresh PowerShell invocations 執行，workload 在兩者之間維持存活，Finalize 能重新取得本次 binding。
- [x] 對 valid authority 執行 Finalize Stop 時，caller 提供的 graceful action 最多執行一次，並只在 caller deadline 內等待。
- [x] graceful Stop 成功時，回傳 lifecycle success、final disposition 與可供 caller 使用的 evidence；本 ticket 不要求 forced termination。
- [x] graceful Stop 完成後，root process 與該次 named ownership object 都已消失，沒有本 ticket fixture 或 temporary artifact 殘留。
- [x] Launch 與 Finalize Stop 的 lifecycle result 和 downstream workload result 以分離欄位回傳；downstream result 失敗時仍不覆寫 lifecycle result。
- [x] happy path 不需要 status、poll、retry、kill、cleanup 或其他第三個 lifecycle action。
