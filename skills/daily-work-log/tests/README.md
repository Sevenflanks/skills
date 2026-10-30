# daily-work-log 回歸

## 固定 capture／選讀與文件 harness

在 repo root 執行局部入口測試；Windows cases 需要 Windows PowerShell 5.1 與 pwsh 7+：

```powershell
pwsh -NoProfile -File skills/daily-work-log/tests/windows-capture.tests.ps1
pwsh -NoProfile -File skills/daily-work-log/tests/capture-cli.tests.ps1
pwsh -NoProfile -File skills/daily-work-log/tests/selection-cli.tests.ps1
python -B -m unittest discover -s skills/daily-work-log/tests -p test_collector_efficiency.py -v
```

`npm run test:daily-work-log` 以 `test_*.py` 納入既有 Codex 與 collector efficiency。CI 保留既有 Ubuntu validate、Windows daily-work-log 與其他 platform gates；Windows job 執行原文件 harness、新 capture／selection CLI cases 及 collector efficiency，讓 Windows-specific native seams 也有實際 CI 執行點。這些是合成正確性／呼叫數／界限測試，不掃私人完整歷史，也沒有五分鐘 CI gate／300 秒 timeout。Repository 完整 validate 留在交付節點集中執行。

`windows-capture.tests.ps1` 逐字執行 [`references/evidence-views.md`](../references/evidence-views.md) 的 fenced recipes。Observer 是經 PS5.1／7 呼叫 bundled capture 與 formatter 的讀者；只替換外部 collector。契約包含公告先於 collect、成功 probe 的固定範圍、BOM-less UTF-8 中文／引號／多行／大型 payload、bounded index／sessions、完整 ERP／草稿、全部 canonical worktree／第二來源／續行、精確原始 raw pointers、不重 collect／不印 raw stdout，以及草稿＋最終日誌 checkpoint 完成後才清理。

此 harness 的檔案 sink 是**合成 checkpoint**，不是實際 agent 對話交付的證明；formatter 不產 posted／delivered receipt，也不授予公開發布。未交付草稿／日誌仍保留 task root，bundled helper 不在清理範圍。`-EvidenceRoot '<existing-external-temp-directory>'` 可保留合成產物，預設自動清理自有暫存。

### Mutation 與穩定性證據

下列命令本輪均已實際 red；每次只變異自有 helper／formatter 副本或合成流程，保留 production 與其他 agent 檔案：

| 命令尾參數（共用上方 windows-capture 命令） | 已觀察的失敗斷言 |
| --- | --- |
| `-Mutation utf16` | `Capture is not BOM-less UTF-8 (UTF-16/default redirect regression).` |
| `-Mutation expanded-index` | `Index expanded private metadata/session/draft content (UTF-8 byte bound).` |
| `-Mutation early-cleanup` | `Render automatically cleaned evidence before delivery checkpoint.` |

固定 repo filter 錯選／漏 worktree 由 canonical repo 與名稱斷言偵測；session filter 漏第二來源／續行由兩筆 session 與 sessionIds 斷言偵測；pointer 重編由 `/repos/1/sessionEvidence/0` 的原始位置與完整 value 斷言偵測；ERP 截斷由大型原文及 546 筆 metadata 完整性斷言偵測；草稿截短／假發布由逐欄全文／destination／published 與原始檔不變斷言偵測。這些額外 mutation 對應為路徑推論，未另改 production 執行。

False-red pins：每輪 GUID 暫存、固定日期字串、隔離 collector、實際 process completion，沒有 sleep／效能 deadline；driver 的 finally 清除自身狀態。日期字串明確固定，避免 PS7 `ConvertFrom-Json` 自動推成 DateTime 與 PS5 行為差異。本輪 green 覆蓋 PS5.1、pwsh 7 與 ANSI-1252 source fallback 三種 caller；mutation 並行執行各自隔離，結束後再跑一次完整正常 harness 確認回復 green。未聲稱實際私人 workload 或端到端耗時收益。

## Codex 日期 gate

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
