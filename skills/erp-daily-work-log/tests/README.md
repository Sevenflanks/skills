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

以上是 0.2.0 的歷史 slices；不是目前完整 suite 的執行聲明。0.3.0 的 mapping 解耦在同一個已核准 prepare／execute＋fake transport seam 驗證，保留原授權、shape、期間及傳輸檢查，將過時的「逾期不寫 mapping」期待改成正確獨立維護行為：

| Slice | 本輪實際 red | Green |
| --- | --- | --- |
| mapping 獨立維護 | 舊 helper 回 output_only/deadline_passed，未進 scoped transport | expired unknown leave／未逾期 unknown leave／full leave／無 report context 均一次固定 POST，payload 日期及欄位正確；仍為 readback_required。 |
| 獨立日期邊界 | 無 context 的非法日期 variants 僅回 invalid_plan_context | 直接拒絕非法 reportDate；舊 context 日期不一致仍拒送。 |

兩次 red 及最後 green 皆執行 `python -B -m unittest discover -s skills/erp-daily-work-log/tests -p test_project_repo_mapping.py -v`；最後 green 為 Python 3.12.0、15 tests 通過（1.206s）。`node scripts/validate-skills.mjs` 的 JSON／catalog 檢查與 `git diff --check` 亦通過；`npm.cmd run` 確認新 script 可由 npm 解析。PowerShell 的 `npm.ps1` 被 execution policy 擋下時使用 `npm.cmd`，不改系統政策。

這次只跑 mapping tests 及局部檢查，完整 ERP tests／`npm.cmd run validate` 留交付節點集中執行。core append／retry 與 preferences tests 由各 owner 維護，不能將其他 owner 的證據算成本輪執行。

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
| 將日誌期限／未知假／全天假 gate 重新套到 mapping，或獨立維護強制要求 report context | `test_independent_mapping_sends_despite_report_deadline_unknown_leave_or_full_leave`（實際精確 POST payload 及讀回狀態，不只檢查 fake 有呼叫） |
| 不驗 reportDate、接受不合法日期／格式，或舊 context 日期與 mapping 默默漂移 | `test_mapping_date_is_validated_without_report_context_and_legacy_date_cannot_drift` |
| CLI 預設寫入、接受token／任意method/url/report授權或錯誤輸出argv/plan | `test_cli_dry_run_and_injected_flags_cannot_authorize_or_leak` |
| update 省略日期就偷偷套 reportDate／null | `test_update_cannot_silently_reset_omitted_old_period_to_new_defaults` |
| 把合法 `.github` 類 repo 誤當 traversal | `test_dot_prefixed_repository_is_not_confused_with_traversal` |

agent 的語意授權、唯一模組證據、report／維護 membership、完整 list／resolver 比對、retry 證據可信度、偏好 scope 及跨端點結果等**不由 mapping unit tests 證明**。對應 [`../evals/evals.json`](../evals/evals.json)，執行狀態見 [`../evals/README.md`](../evals/README.md)。helper 不猜權限或自行 GET 清單；agent 必須依文件完成 fresh 維護權限、完整 list、期間與 modifiedTime 核對。正式 server 權限／period lock／concurrency 與部署契約未連線驗證。

## 重跑

```powershell
npm run test:erp-daily-work-log
npm.cmd run validate
git diff --check
```

`test:erp-daily-work-log` 執行既有 unittest discover，`validate` 只透過該 script 接一次；CI validate job 設定 Python 3.12 後仍只跑 `npm run validate`，無新框架或 dependency。局部 mapping 檢查可用上列 `-p test_project_repo_mapping.py` 命令。

本輪測試同步結束，沒有啟動常駐 process。CLI subprocess 有 timeout；fixture 暫存檔由 TemporaryDirectory 清理，沒有真 ERP 或實際 config 讀寫。Python 其他版本未在本輪實跑。
