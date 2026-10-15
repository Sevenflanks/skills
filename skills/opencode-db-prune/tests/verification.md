# 驗證與 mutation 對應

執行真實 SQLite 與 Windows sharing/ReplaceFileW fixture，不讀寫使用者 DB。測試暫存目錄在 tests 下，正常結束即清除；跨平台執行時 Windows 整合案例明確 skip，不可當作已驗證其他 OS。

| 可能的錯誤修改 | 會失敗的測試 |
| --- | --- |
| cutoff 改成 `>`、改近期 JSON、裁掉 bash output 或 exit | `test_recent_raw_rows_and_deja_fields_survive_while_old_auxiliary_is_removed` |
| 30 天改成曆月、忽略時區 | `test_30_days_is_720_hours_across_month_end_and_offset` |
| plan 寫來源、重用 candidate 名稱或後移已固定門檻 | `test_plan_is_readonly_and_each_run_has_frozen_policy_and_unique_names` |
| 不含執行授權仍進入重建 | `test_cli_missing_any_execution_acceptance_cannot_checkpoint_or_create_candidate` |
| 讀入不同 policy 後切換 | `test_changed_policy_cannot_promote_validated_candidate` |
| 丟失 sequence 內表、重用已配置 ID | `test_legacy_sequence_table_without_autoincrement_is_preserved` 與原始保留測試 |
| 遺漏 shell/edit/write/patch input 或非 bash 工具保留規則 | `test_all_retained_edit_and_shell_inputs_survive` |
| 移除未知 schema／非空替代 store 閘門 | `test_unknown_schema_stops_before_candidate_creation`、`test_nonempty_alternative_store_refuses_before_creating_candidate` |
| 路徑重疊或磁碟不足仍繼續 | `test_same_path_report_in_source_directory_and_low_space_are_refused` |
| 並行進行同一來源維護，或後到 build 覆寫已驗證 report | `test_lease_blocks_duplicate_maintenance_without_creating_candidate`、`test_second_build_after_preflight_cannot_overwrite_first_validated_report` |
| Guard 改成 metadata-only handle | `test_guard_blocks_real_writer` |
| 中斷直接污染原檔 | `test_interrupted_build_leaves_original_bytes_and_rows_intact` |
| candidate/source 內容改變但 size/mtime 相同仍允許切換 | `test_tampered_candidate_cannot_replace_original`、`test_source_edit_with_restored_mtime_cannot_discard_new_data_during_promotion` |
| promotion gap 有 writer 仍刪原檔或盲目回復 | `test_writer_in_promotion_gap_preserves_both_databases` |
| replace 部分失敗後清掉 rollback | `test_partial_replace_failure_keeps_original_under_actual_rollback_name` |
| 單一檔案形式的外部 index 改變未發現 | `test_changed_single_file_deja_index_restores_original_and_keeps_candidate` |
| 原檔刪除後 report 寫入失敗卻聲稱仍保留 | `test_report_failure_after_deletion_does_not_claim_original_retained` |
| 刪除前 pathname 被替換，誤刪同名檔 | `test_rollback_path_replacement_before_delete_cannot_delete_unrelated_file` |
| 已開 DELETE handle 後 pathname 被換，刪到新檔 | `test_rollback_rename_after_delete_handle_open_never_targets_new_path_occupant` |
| 無視來源破損 FK 或 part/message session 不一致 | `test_invalid_source_references_or_session_ownership_stop_before_candidate` |
| 第二次清理丟 session/message 或沒有進一步老化保留內容 | `test_second_month_rebuild_retains_all_session_message_ids_and_further_ages_parts` |
| 缺少 Deja 就阻擋一般維護，或完整保留模式遺失原始值／替代 store | `test_default_compact_without_deja_reclaims_space_and_retains_every_raw_row` |
| 缺少 Deja 就拒絕激進清理 | `test_aggressive_mode_without_deja_can_plan_build_and_promote` |
| 偵測到 Deja 就自動套激進模式 | `test_deja_present_does_not_automatically_select_lossy_mode` |
| Deja 不在 PATH 就刪掉其既有 cache | `test_existing_deja_cache_is_preserved_even_without_executable` 與 `test_existing_deja_cache_survives_build_and_promotion_without_executable` |
| 舊／缺少模式的 policy 被當成激進模式使用 | `test_old_or_missing_mode_policy_is_rejected_instead_of_assuming_deja` |
| Windows PATH 的 cmd shim 未被偵測 | `test_real_path_discovery_finds_windows_cmd_shim` |
| Python 3.11 的 which 不認 PATHEXT 未列出的 .ps1 | `test_path_ps1_discovery_survives_legacy_which_not_recognizing_extension` |
| 切換成功但未驗證／未釋放原檔 | `test_validated_atomic_promotion_then_deletion` |

| quick 誤掃歷史、寫來源或聲稱候選大小保證 | `test_quick_audit_does_not_scan_history_and_reports_freelist_without_size_promise` |
| 未知 schema 診斷遺漏差異／洩漏 SQL literal | `test_schema_diagnostic_reports_added_and_changed_objects_without_sql_values` |
| 發布的 schema 結構與 fingerprint 脫節 | `test_published_schema_manifest_matches_its_real_sqlite_structure` |
| 估算與 build 採不同保留分類 | `test_estimate_and_build_agree_on_retention_for_every_table` |
| keep 仍刪原檔，或 purge 未授權就刪除 | `test_keep_original_then_purge_requires_separate_authorization` |
| purge 忽略原檔 SHA/sidecar，或不允許新 DB 正常增加資料 | `test_purge_allows_valid_updates_but_refuses_tampered_original_and_sidecars` |
| 目前 DB 被替換仍允許 purge | `test_purge_refuses_replaced_active_database` |
| inspect-run 開錯 DB/WAL 或自動重試／刪檔 | `test_inspect_partial_replace_never_opens_sqlite_or_pairs_source_wal_with_candidate` |

未覆蓋：硬體故障與斷電、所有 Windows sharing race、真正 OS 回傳 1177 的條件組合（測試在 replace 邊界注入同樣的部分完成副作用）、真實 Deja 搜尋／重新索引。磁碟輪詢不是硬 quota。人類是否授權、使用者要求的選用工具相容性是否經 agent 核對，另由 skill 行為 evals 驗證；CLI 旗標不能證明人類曾同意。
