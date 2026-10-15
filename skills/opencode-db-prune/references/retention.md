# 保留規則與相容性

## 完整保留模式（compact，預設）

所有表與每列原始值都保留，包括 message/part 的完整 JSON、所有 event/sequence、非空替代 store、schema、migration、SQLite metadata 與 rowid。重建只回收閒置頁與重排空間，沒有日期門檻，也不需要 Deja 或其他查找工具。

## 激進模式（aggressive，明確選用）

以下政策是通用的內容取捨，來源於以歷史查找為主的使用需求，未安裝 Deja 也可選用。它不承諾 OpenCode 原生 UI 或任一查找工具能完整續跑／還原舊 session。

| 資料 | 近期 session | 舊 session |
| --- | --- | --- |
| session | 所有欄位原樣 | 所有欄位原樣 |
| message | 所有欄位、原始 JSON 原樣 | 所有列與欄位；僅 `summary.diffs` 陣列改為 `[]`，保留 property |
| text part | 原樣 | 完整原文，不套用索引工具的文字長度上限 |
| tool part | 原樣 | 只保留 `read/bash/shell/apply_patch/patch/edit/write` |
| 保留工具的 input | 原樣 | 全文原樣，包括 command、path、patch、old/newString、content |
| 保留工具的 output | 原樣 | bash/shell 全文，其餘存在的 output 改 `""` |
| 工具 metadata | 原樣 | `state.metadata` object 只保留 exit；root metadata object 清成 `{}` |
| 其他工具欄位 | 原樣 | status、error、time、title 等原樣 |
| 其他 part | 原樣 | 移除，包括 reasoning、附件、step marker、task/MCP 等工具 |
| event / event_sequence | 全列原樣 | 兩者對應的舊 session 列一起移除 |
| 其他表與 SQLite metadata | 原樣 | 原樣 |

門檻依 session 的 `time_updated`（Unix milliseconds）判斷，`>=` 包含邊界。message/part 自身時間不決定保留；子 session 不繼承父 session 的近期狀態。開始時固定 cutoff，最後離線時重新取近期 IDs。

## Schema 契約

[compatibility.json](compatibility.json) 記錄經實機重建驗證的 schema ID、完整公開結構與 fingerprint，以及 Deja reader revision。fingerprint 僅取公開結構，不含實際記錄或憑證。

兩種模式均僅接受已知 schema；激進模式額外要求 `session_message/session_context_epoch/session_input` 替代 store 為空，完整保留模式則原樣複製非空替代 store。存在未知表、view、trigger、內部表或 schema SQL 不同時拒絕。migration/user_version/application_id/page_size、所有未處理表與顯式 rowid 原樣保留。legacy `sqlite_sequence` 即使已無 AUTOINCREMENT table 仍保留，避免重用已配置的 ID。

相容性改版需先比對實際 schema、來源 migrations、對話讀取路徑，以及使用者要求保證相容的查找工具 reader（如有），再補 fixture 與回歸測試；不能直接放寬白名單或改 fingerprint 讓它通過。新 column 可能改變事件重建、FK 或查找來源，不應猜測。

## 選用的 Deja 相容性

查核來源：[OpenCode reader](https://github.com/vshulcz/deja-vu/blob/0325357ed2d39d125f1183e81e4658c48d5081c1/internal/sources/opencode.go)。此 revision 的 OpenCode V1 讀取文字、read 路徑、bash command/output/exit、apply_patch 與 edit/write 輸入，以及角色、summary flag、時間、synthetic/ignored；V2 reader 使用其他 store，不能套用 V1 精簡。

Deja 不是任一清理模式的依賴。只有使用者要求維持 Deja 原有查找能力時，才取得本機版本並對應 release/source，確認沒有新增激進規則會移除的必要欄位或工具。shell/patch 為額外保留，完整 input 比目前抽取範圍更寬。helper 驗證重建內容及保留工具抽取欄位，**不宣稱已實際執行 Deja 搜尋或重建其 index**。

偵測到既有 Deja `index.db` 時予以保留，它可能是檔案，也可能是目錄；自訂 cache 位置須加入 preserve-path。保留 OpenCode `storage/session_diff`。兩者切換前後均核對內容 digest。既有 index 可能還有來源 DB 已不存在的歷史，不能為了騰空間一起移除；也不能將 index 的截斷／去識別化內容當完整備份。

## 為什麼使用重建

SQLite 刪列後通常只是增加 freelist；縮小檔案還需要重整。此流程將選中的內容寫進新 DB，避免在唯一原檔做 DELETE/VACUUM。原檔在切換前後驗證期間保留；預設 keep 會繼續保留，明確選 delete 或日後 purge 才刪除。只有刪原檔會不可逆。

`VACUUM INTO` 會複製整份有效內容，並不會實作這個保留政策；原檔直接複製也不能忽略 WAL。來源讀取使用 SQLite snapshot；只有 checkpoint、sharing guard 與無 sidecars 同時成立才使用 immutable。參考 [SQLite URI immutable](https://www.sqlite.org/uri.html) 與 [VACUUM](https://www.sqlite.org/lang_vacuum.html)。
