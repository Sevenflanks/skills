# opencode-db-prune

快速健檢、估算並維護 OpenCode DB。**Deja 是選用整合，沒有安裝也能使用完整保留或激進模式。**

| 模式 | 保留方式 |
| --- | --- |
| `compact`（預設） | 所有表、JSON、附件、工具內容、event 與 sequence 原樣複製，回收閒置頁與重排空間 |
| `aggressive`（明確選用） | 最近 30 天完整保留，所有 session/message 保留；較舊資料精簡為文字與指定工具內容 |

每月先做快速健檢，必要時再完整估算：

> 使用 `$opencode-db-prune` 先快速健檢，再按需要估算完整保留與激進模式能回收多少，不要修改 DB。

看過計畫後明確選擇。預設切換後保留原檔，尚未回收空間；可另行授權 verified purge。需要立即釋放空間時，例如：

> 執行激進清理，近期保留 30 天，不另做完整備份，驗證成功後刪原檔；等 OpenCode 全部退出才開始。

僅呼叫 skill 不會改 DB，也不會建立排程。激進模式固定 30 天即 720 小時，與曆月不同；完整保留模式沒有日期門檻。兩種模式都繼續累積保留資料，建議每月依估算決定是否執行。

激進模式會移除較舊的 reasoning、附件、部分工具內容與 event replay，不保證舊 session 完整續跑／還原。選擇依據是可接受的資料取捨，不是是否裝了 Deja。完整規則見 [retention.md](references/retention.md)。

helper 自動從 PATH 偵測 Deja（含 Windows shim），另保護已存在的 cache；可用 `--deja-executable` 提供不在 PATH 的位置。未找到 Deja 不會阻擋任一清理模式，也不會要求安裝。若要求維持特定工具的查找能力，需另確認該工具 reader 版本相容；cache 不是原始資料備份。

此版本支援 **Windows 離線重建與切換**，需 Python 3.11+，無 pip 依賴。非 Windows 可做 quick、SQLite 唯讀估算與 inspect-run 診斷，寫入會拒絕。兩種模式都檢查 OpenCode schema；激進模式另外要求替代對話 store 為空。

安裝時複製整個資料夾，保留 scripts、references 與 tests。CLI、報告位置、鎖與恢復見 [operations.md](references/operations.md)。`0.1/0.2` 的舊 policy/report 需重新 plan，不直接沿用。

開發驗證（在本 repo root）：

```powershell
python -m unittest discover -s skills/opencode-db-prune/tests -v
npm run validate
```

測試只使用獨立 SQLite fixture；不讀寫使用者的正式 DB。測試風險對應見 [tests/verification.md](tests/verification.md)。
