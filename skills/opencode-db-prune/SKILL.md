---
name: opencode-db-prune
description: 估算與維護過大的 OpenCode SQLite DB，適用於磁碟回收與每月維護。預設完整保留重建，也可明確選用近期 30 天完整保留的激進精簡；Deja 為選用整合，未安裝也能執行兩種模式。
license: MIT
metadata:
  author: sevenflankse
  version: 0.3.0
---

# OpenCode DB Prune

先估算可回收量，明確要求「執行清理」才修改 DB。沿用本次已確認的模式與授權，不重複詢問。僅呼叫 skill、詢問方案或提到每月維護，均只授權唯讀分析。

## 1. 快速健檢、選擇模式並估算

定位實際 OpenCode DB 與 `storage/session_diff`；尊重 XDG 或使用者自訂路徑。確認 Python 3.11+ 與 SQLite 能唯讀開啟 DB。helper 使用 standard library；Windows 才支援重建及切換。

每月先跑 `quick`：只讀 main/WAL 大小、page/freelist 與 schema 診斷，預設閒置頁至少 1 GiB 且占 10% 才建議完整保留估算。門檻可調；低於門檻不代表激進模式無效益，使用者明確要求完整估算時仍跑 `plan`。quick 不掃歷史、不預測精確新 DB 大小，也不證明離線。

使用者未指定模式時採 `compact`：完整複製所有表、原始內容與 event，回收閒置頁與重排空間，不刪歷史。使用者明確選「激進模式」才採 `aggressive`：[保留規則](references/retention.md) 包含所有 session/message、近期完整內容及較舊的文字／指定工具，會失去舊 reasoning、附件、其他工具內容與 event replay；不保證舊 session 完整續跑／還原。先交代取捨，再執行已授權的模式。

兩種模式都不需要 Deja。helper 自動從 PATH 尋找 Deja，Windows 同時處理 exe/cmd/ps1 shim；不在 PATH 可傳 `--deja-executable`。只找到 cache 不等於找到可用程式，找到程式也不等於 reader 版本相容。偵測結果僅供選用整合與保護既有 cache，不能自動選用激進模式或要求安裝 Deja。

以 [helper 操作](references/operations.md) 的 `plan` 建立獨立 run directory。激進模式預設最近 **30 天，即 720 小時**，以 `session.time_updated >= cutoff` 判定；固定在 `policy.json`，等待期間不後移。完整保留符合條件的 session，即使它早於門檻建立；子 session 各自判定。完整保留模式沒有日期門檻。

使用 `estimate.json` 呈現模式、來源大小、新 DB 與回收估算範圍、所需可用空間，以及保留／移除數量。估算來自 SQLite snapshot，執行前資料仍可能增加；實際大小以重建完成為準。回收效益低或估算會變大時，建議略過。兩種模式都繼續累積保留資料，月清不保證 DB 大小固定。

## 2. 確認授權與離線

估算完成且符合需求後，若尚未收到明確執行指令，回報計畫並保持來源原樣。plan 預設 `--original keep`：切換驗證後保留原檔，不另複製原 DB；此時仍占用原檔加新 DB 空間，尚未回收磁碟。明確選 `--original delete` 且接受不另做完整備份／驗證後刪原檔，才立即回收。保留原檔者可日後另行授權 `purge`；完整備份的特殊要求仍須另行完成，保留原檔不等於異碟備份。不得沿用其他人的 backup waiver。

執行前核對 OpenCode schema；不同或不支援時停在唯讀分析；報告 schema SHA、已支援結構、物件差異及 SQLite metadata，不輸出 SQL literal。激進模式遇非空替代對話 store，也先確認相容性並更新實作／測試，不直接換 fingerprint。若使用者要求保證 Deja 等查找工具的原有查找能力，另核對該工具實際版本與 reader 所需欄位；未知相容性不能冒稱已通過，但不是通用清理的必要依賴。

以 `status` 或可靠主機程序工具證實 **全部 OpenCode 程序已退出**。sandbox 空清單、DB 停止變動或觀察失敗都不是完成證據；必要時使用 host escalation。仍在執行時安靜等待，不終止 session、不關程式。其他 reader/MCP 若造成鎖定，保留來源並回報需釋放的鎖，不強制終止。

只有使用者已要求等待／監控才建立 heartbeat；僅停止本次維護的重複觸發，不改其他 automation。長時間 process 沿用可用的 `agent-process-lifecycle` 或具名 external owner 契約；否則留在可持續觀察的同步工具，不能背景啟動後失去管理。

## 3. 重建、驗證、切換

依操作 reference 使用同一份 `policy.json`，先 `build`、再 `promote`。執行旗標只表達已取得的本次授權，不能代替人類決定。來源目錄寫入依平台權限送審；被拒絕時停在安全狀態並說明原因。

helper 完成 WAL checkpoint、確認無 sidecars 後取得 Windows sharing guard，從一致唯讀來源建立同目錄 candidate。模式寫進 policy 並綁定 report；完整保留模式逐列原樣複製，激進模式從最後離線來源重取近期 IDs。先資料再索引，保留 schema、migration、rowid 與 SQLite metadata。預設保留至少 8 GiB 餘裕；不足就停止並保留原檔，原 DB 不做 DELETE/VACUUM。

`candidate_validated` 才能切換：完整 integrity／FK、schema、各表內容雜湊與檔案 SHA256 均通過。`promote` 再核對來源／candidate 身分、policy 與內容，以 `ReplaceFileW` 將原檔留為暫時 rollback。切換後核對內容、FK 與所有 preserve paths；全部通過後依固定 policy 保留原檔，或以綁定原檔身分的 DELETE handle 刪除。估算與 build 共用同一保留管線，避免兩套分類規則漂移。精確閘門與失敗處置見操作 reference。

## 4. 收尾與每月重跑

報告模式、實際新舊 bytes／GiB、回收量、適用時的 cutoff、session/message 保留數、part/event 移除數與驗證結果。只存計數、digest、狀態與必要本機路徑，不輸出對話、憑證或反射資料的錯誤訊息。只有 `complete` 且檔案吻合才能宣告已回收；`original_retained` 表示切換成功但尚未回收，須報告原檔占用與淨磁碟變化。

下次重新 `plan`，使用獨立 policy/candidate/report；激進模式重算新的 30 天門檻。不得繼承舊授權、估算、report 或原檔身分，也不將舊 `deja-v1` 計畫默轉成新模式。有未完成 run 時先用 `inspect-run` 對照記錄階段、實際 file ID、可選 SHA 及 sidecars；此指令只讀檔案，不開 SQLite 或套用 WAL，再按操作 reference 核對狀態，不盲目重試或清除 rollback。
