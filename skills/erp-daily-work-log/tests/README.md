# Regression 與 mutation list

Python unit tests 在 plan→dry-run／scoped transport seam 執行真實 helper，僅 network／credential access 用合成 fixture 替代。不查 SKILL.md 原文或常數標籤。

## Red → green 證據

| Slice | 觀察到的 red | Green 後能力 |
| --- | --- | --- |
| 新 helper／日期預設 | helper 缺檔，原 37 tests 通過 | 新增 dry-run 定稿日期，不讀 credential。 |
| shape／update | 18 個非法欄位 subcases 未拒絕、update 未支援 | strict fields／Long／日期、PUT 排除 projectId、原 timestamp 不截精度。 |
| 獨立授權／transport | save 沒呼叫 transport、缺契約未拒絕 | 獨立 mapping-confirmed 與 contract-verified；精確 dry-run/write payload、TLS與readback。 |
| CLI | CLI 回 use --help，dry-run exit1 | 正式 CLI、預設 dry-run、未知／credential flags 去敏拒絕。 |
| update 日期 | 三種省略日期 variants 未拒絕 | update 強制兩個日期明填，避免默用新增預設裁舊期。 |
| repo shape 相容 | 合法 `acme/.github` 誤報 invalid_mapping_repo | 允許 dot-prefix，仍拒絕 `.`／`..` path segment。 |
| modifiedTime wire format | `modified_time` 接受空白分隔的秒精度字串 | 僅接受官方目前 readback 的 `T` 分隔 local ISO；`test_modified_time_accepts_readback_iso_precision_and_rejects_legacy_space_seconds` 覆蓋原字串及 0／1／6／9 位 fractional precision，並拒絕空白分隔秒格式。 |

最終 Python 3.12.0：51 tests 通過（原 `test_daily_report.py` 37 保持原樣＋`test_project_repo_mapping.py` 14）。Python 3.8 未實跑；原 `test_fractional_timestamps_use_python38_iso_parser_precision` strict double 保留通過，不等於完整 runtime 驗證。新增的空白分隔秒格式拒絕測試已在舊 helper 上觀察到 red；其他純回歸中的錯誤情境沿用既有 transport 行為，未聲稱每項都曾對 baseline 觀察到 red。

## Mutation list

以下是能讓對應測試失敗的具體變異與 oracle；未啟動 mutation framework，不宣稱 mutation score。

| Plausible mutation | 會失敗的 `test_project_repo_mapping.py` 測試 |
| --- | --- |
| dry-run 讀 credential／改預設日期或產生不同有效期 | `test_default_dates_are_frozen_in_dry_run_without_credentials` |
| PUT 傳 projectId、丟失 null 期間、截斷／重排 modifiedTime | `test_update_preserves_readback_timestamp_and_never_sends_project_id` |
| 接受任意 method/path/url、舊 id/module、bool／字串／溢位 ID、不合法 repo／branch／日期或倒置期間 | `test_invalid_fields_ids_dates_and_arbitrary_operations_fail_before_access` |
| update 不驗 id、遺失 timestamp／接受錯誤 local timestamp | `test_update_requires_id_and_original_legal_local_timestamp` |
| modifiedTime regex 接受空白分隔秒格式、拒絕官方 `T` readback 或改寫精度 | `test_modified_time_accepts_readback_iso_precision_and_rejects_legacy_space_seconds`、`test_update_preserves_readback_timestamp_and_never_sends_project_id` |
| 不需獨立 save 確認、以 truthy 字串授權、略過 contract 或接受 report authorized | `test_mapping_confirmation_is_separate_from_contract_and_report_authorization` |
| operation 指錯 path/method、payload 與 dry-run 不同、token 進結果、TLS 不驗證、follow redirect、200報完成 | `test_confirmed_create_and_update_send_exact_dry_run_payload_once` |
| overlap/stale 應用錯誤視為成功、自動 retry／改期 | `test_overlap_and_stale_application_errors_require_readback_without_retry` |
| timeout／HTTP／403／404／409 直接重試或反射原 exception／body | `test_network_and_http_rejections_are_redacted_single_attempts` |
| HTML／非object JSON／超大回應／success=false當成功 | `test_non_json_malformed_and_oversized_success_are_not_saved` |
| 逾期時先問未知工時、進 mapping／credential、把nanosecond截成可寫；fullleave不stop | `test_expired_unknown_hours_and_full_leave_do_not_require_mapping_or_access` |
| CLI 預設寫入、接受token／任意method/url/report授權或錯誤輸出argv/plan | `test_cli_dry_run_and_injected_flags_cannot_authorize_or_leak` |
| update 省略日期就偷偷套 reportDate／null | `test_update_cannot_silently_reset_omitted_old_period_to_new_defaults` |
| 把合法 `.github` 類 repo 誤當 traversal | `test_dot_prefixed_repository_is_not_confused_with_traversal` |

agent 的語意授權、唯一模組證據、report／維護 membership、完整 list／resolver 欄位比對、跨端點結果與衝突時不自動改寫等**不由 Python unit tests 證明**。對應 [`../evals/evals.json`](../evals/evals.json) 19–32；本輪另以 fresh consuming agents 執行 8 個選定合成情境，結果與限制見 [`../evals/README.md`](../evals/README.md)。這不是完整案例／變體的自動 evalrunner，不能算入 unit coverage。正式部署的 server 權限／period lock／concurrency 與契約尚未連線驗證。

## 重跑

```powershell
python -B -m unittest discover -s skills/erp-daily-work-log/tests -v
npm.cmd run validate
git diff --check
```

本次皆同步完成，沒有啟動常駐 process。CLI subprocess 有 timeout；fixture 暫存檔由 TemporaryDirectory 清理，沒有真 ERP 呼叫。
