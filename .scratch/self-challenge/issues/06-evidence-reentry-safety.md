# 06 — 限制 evidence、failure 與 reentry 行為

**What to build:** 為 `MORE_EVIDENCE`、sub-agent failure 與重入建立明確界線，確保自我質疑不會變成無限調查、重試循環或在證據不足時替 pivot 背書。

**Blocked by:** 05 — 實作 source-first 的 stage-two 對抗流程

**Status:** resolved

- [x] 每個 `MORE_EVIDENCE` verdict 必須指出一個 decision-relevant question、一個最小 read-only investigation 或 test、明確 completion signal 與不得擴張的範圍。
- [x] `MORE_EVIDENCE` 期間禁止先做 direction-changing edit；取得新證據後必須重新套用四種 verdict 的 precedence。
- [x] 若補充證據後仍存在 user-owned directional ambiguity，停止並詢問使用者，不得以更多自主調查迴避決策權。
- [x] 同一組 confirmed-intent baseline、candidate action 與 decision-relevant evidence，每個 pivot 最多執行一次 stage two，不得 retry 或 recursive invocation。
- [x] Timeout、source retrieval failure、malformed output、missing verdict 或無法證明 read-only 都不得作為偏離 confirmed intent 的支持證據。
- [x] Stage-two failure 只能導向 bounded `MORE_EVIDENCE` 或保留既有基線；只有 evidence 或 candidate materially changes 時才允許新的 cycle。
- [x] Failure 與 reentry fixtures 證明流程不會寫檔、不會建立第二個 challenger、不會無限循環，也不會把工具失敗誤判成 plan assumption 已失效。
