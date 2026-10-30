# Codex collector 回歸

在 repo root 執行以下最小日期 gate 回歸；需要 Python 3.11+、PowerShell 7 與 Git：

```powershell
python -B -m unittest discover -s skills/daily-work-log/tests -p test_codex_collection.py -k date
python -B -m unittest discover -s skills/daily-work-log/tests -p test_codex_collection.py -k not_null
python -B -m unittest discover -s skills/daily-work-log/tests -p test_codex_collection.py -k covering
python -B -m unittest discover -s skills/daily-work-log/tests -p test_codex_collection.py -k outside_history
```

## 公開 CLI seam

新增日期 gate 案例透過 `collect-daily-work-log.ps1`，只傳入自建 SQLite、exact rollout、repo 與不存在的其他來源路徑。判定使用輸出的 adapter status、候選證據、fallback coverage 與診斷；不以私有 query builder 的呼叫次數或原始碼文字判定。

1. **NOT NULL 秒欄位**：舊建立日、archived rollout 與 SQL 當日證據必須保留，不能因不可能的 NULL 分支退回日期掃描。測試同時核對 fixture DB 的 SHA-256／mtime 不變。
2. **NOT NULL 毫秒欄位**：毫秒為權威時間，秒值為 NULL 且無秒 index 時仍可選中候選；不要求不存在機會執行的秒 fallback。
3. **nullable／未知時間**：保留候選以讀取有實際日期的 SQL／exact 證據；未知時間事件本身不可猜日期，仍回報 partial。
4. **covering index**：全投影欄位均在既有日期 index 時，合法 SEARCH 必須保留 SQL／archived exact 證據。
5. **不安全計畫與診斷**：fixture 對日期欄位使用不匹配的 collation index，迫使真實 SQLite 產生 SCAN。必須在 SQL row 回傳前拒絕，保留有界日期 fallback；缺 index 與計畫拒絕分別提供固定 reason／branch。診斷不得包含工作原文、路徑或自訂 index 名稱。

## Codex canonical evidence 與隔離

新增公開 collector CLI 案例覆蓋 runtime version 僅供診斷、canonical `item_completed`／SQL mirror identity、必要 query capability 與單筆錯誤隔離。可讀取時，unknown／missing／不同版本不阻擋候選；unknown time、無效內容、型別或 item 只形成明確 gap，不被報為成功 EOF，也不隱藏後續有效 item／候選。缺必要 schema／index 或實際 query plan 不安全時，保留已成功證據並沿既有有界 fallback；版本差異本身不產 compatibility draft。具體案例見 `test_codex_collection.py` 中 `test_version_is_diagnostic_only_including_absent_column_and_mixed_candidates`、`test_bad_history_item_is_isolated_and_later_items_and_candidates_survive`、`test_canonical_messages_use_materializer_time_and_item_identity`、`test_canonical_tools_mirror_sql_without_merging_distinct_outputs_or_errors`、`test_compatibility_drafts_classify_observed_query_time_and_content_gaps` 與 `test_history_without_thread_index_never_scans_unrelated_items_and_keeps_exact`。

目前 state SELECT 沒有排序子句；上述公開 seam 的正常 table fixture 不會自然產生 temp-sort。程式仍拒絕 `USE TEMP B-TREE`，但此分支不宣稱已由這組 CLI 回歸直接觸發。

## 測試判定依據

- 恢復 NOT NULL 欄位的 NULL 分支：`test_not_null_seconds_keep_indexed_archive_candidates_without_date_fallback` 失敗；原實作已實際 red，修正後 green。
- 恢復只接受普通 INDEX 的 matcher：`test_covering_date_indexes_keep_sql_and_archived_exact_evidence` 失敗；已實際 red→green。
- 刪除 nullable 未知時間候選：既有 `test_unknown_metadata_and_item_dates_do_not_hide_later_dated_work` 會失去 archived exact／有效 SQL 證據。
- 全面接受 SCAN 或移除拒絕診斷：`test_unsafe_date_index_scan_reports_safe_branch_plan_and_keeps_bounded_fallback` 的狀態／branch／plan／隱私斷言會失敗；缺 index 診斷另由 `test_no_date_index_declares_gap_and_uses_only_bounded_date_fallback` 驗證。

除已標示的 red→green，其餘 mutation 對應為程式路徑推論。每個 case 自有 temporary directory、固定日期與 isolated PATH；collector 子程序等待實際輸出，45 秒只作逾時上限，逾時會清除 process tree。測試結束關閉 fixture connection 並清除暫存目錄。
