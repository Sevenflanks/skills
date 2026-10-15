# 永久儲存 repo mapping

只在未逾期、非整日請假，且本次需要新增／更新 mapping 時使用。本次 project 選擇與永久儲存是兩個意圖；引文、歷史紀錄、否定與日誌「直接提交」不授權儲存。已有有效 mapping 不必再寫。

## 1. 讀部署契約與可維護資料

用外部 `erp` 唯讀 skill 查官方 OpenAPI 與完整 `$ref`，以下是實作契約，不是部署宣告；維護權限沿用 ERP 畫面／API key owner，不能從 report project 選項推定。

| Operation（前綴 `/api/v2`） | 正式格式 |
| --- | --- |
| GET `/project-repo-mappings/projects` | `AjaxResponse<List<ProjectRepoMappingProjectView>>`，可維護的 projects，不等於可填報 projects。 |
| GET `/project-repo-mappings?projectId=...` | `AjaxResponse<List<ProjectRepoMappingView>>`，完整 list，含 id、projectId、repo、branch、validFrom、validTo、modifiedBy、modifiedTime。 |
| POST `/project-repo-mappings` | `ProjectRepoMappingSaveRequest {projectId,repo,branch,validFrom,validTo}` → `AjaxResponse<ProjectRepoMappingView>`。 |
| PUT `/project-repo-mappings/{id}` | `ProjectRepoMappingUpdateRequest {repo,branch,validFrom,validTo,modifiedTime}` → 同上；不接受 projectId 更新。 |

缺維護 operation／schema、無維護權限或使用者拒存：記錄「本次不永久儲存」，已確認合法 project 仍可填報。缺原 context／report API 或認證、來源缺口，仍依主流程停止。查詢都走外部 readonly helper；POST／PUT 只用本 skill scoped helper，不改 readonly guard、不偽裝 readonly POST、不用 browser Cookie。不新增 DELETE／upsert。

## 2. 預覽差異與授權

1. 先確認 repo 的 `owner/repo` 與當日可靠短 branch；推定 branch 不能變永久資料。用完整 list 找要更新的原 id，不從 report detail 或 module ID 借值。
2. 列出「新增」或「更新 id」、repo、branch、project 的 API ID／label、validFrom／validTo，以及更新前→後差異。新增缺省為 **reportDate 起、無上界**（`validTo=null`），要在預覽明說；update 明確沿用或修改舊期間，含 null 邊界，不能省略而默換。
3. 問「本次日誌使用此專案」及「是否永久儲存上述 mapping」，可在同一預覽分別回答。只有正向明確儲存意圖才記 `--mapping-confirmed`。拒存不影響本次合法 project。
4. 列出已知重疊／其他 project 歸屬／stale 衝突並先問。不能為了 save 自動刪舊、裁短、切分、改 project 歸屬或補另一筆。合法 reference membership、跨 project 期間鎖及樂觀鎖由 server 最終判斷。
5. 寫前先 GET fresh context 跑主流程分流；再查可維護 projects／完整 list 並比較 id、欄位、期間、原 modifiedTime。變更先重做差異與確認，不把新 timestamp 默塞舊授權。核對後固定 plan，先 dry-run，寫入相同 payload；不要在兩次呼叫間換日期或欄位。

## 3. Scoped helper plan

與 report helper 共用安全 config、HTTPS、NoRedirect、timeout、去敏錯誤與 context gate；不新增 dependency。保留整個 skill 資料夾，`project_repo_mapping.py` 會載入同資料夾的 `daily_report.py`。兩個 helper 沒有共用授權 flag。

root 只接受 `reportDate`、官方完整 `context`、可選 `totalHours`／`confirmedLeaveHours` 及 `mapping`；context 格式見 [`helper.md`](helper.md#私有-plan)。不放 report `rows` 或舊 detail。以下合成範例可直接 dry-run，請用私有 task-local JSON，清理方式同 report plan：

```json
{
  "reportDate": "2026-10-14",
  "context": {
    "reportDate": "2026-10-14", "details": [], "expectedSnapshot": "synthetic-snapshot",
    "serverNow": "2026-10-14T18:00:00+08:00", "replaceDeadline": "2026-10-15T10:00:00+08:00", "canReplace": true,
    "leaves": [], "leaveHours": 0,
    "attendances": [{"id": 41, "recordTime": "2026-10-14T09:00:00", "classification": "ATTENDANCE", "leaveType": null}]
  },
  "mapping": {
    "operation": "create", "projectId": 7, "repo": "acme/widget", "branch": "feature/billing",
    "validFrom": "2026-10-14", "validTo": null
  }
}
```

- create：`operation=create`、Long `projectId`、非空 repo／branch；缺 `validFrom` 以 reportDate 補定、缺 `validTo` 補 null，dry-run 顯示定稿 payload。明確 null 是無界；日期為 yyyy-MM-dd，起訖不得倒置。
- update：改 `operation=update`，另填 Long `mappingId` 與 GET 原始 `modifiedTime`；`projectId` 僅供預覽／識別原歸屬，**不進 PUT payload**。validFrom／validTo 兩欄都必填（可 null），明確沿用或修改，避免誤套新增預設裁期。timestamp 僅接受官方目前 `ProjectRepoMappingView` 讀回的 `yyyy-MM-ddTHH:mm:ss[.1至9位小數]` local ISO datetime（無 timezone）；保留原字串傳送，不換時區、不截精度。這是對官方目前讀回格式的支援，不宣稱涵蓋所有 Web／legacy 輸入格式，也不是 context 的 +08:00 timestamp。
- helper 僅驗證 shape；projectId／mappingId 為 signed Java Long（不收 bool／字串），存在性與權限交 server。未知欄位、module、舊 row id、任意 URL／method／path 皆拒絕。branch 的真實性與合法業務語意仍由 agent 證據及 server 核對。

```powershell
python -B "<skill>/scripts/project_repo_mapping.py" --plan "<private-mapping-plan.json>"
# 僅永久儲存確認、部署契約與 fresh gate 都通過才執行：
python -B "<skill>/scripts/project_repo_mapping.py" --plan "<private-mapping-plan.json>" --mapping-confirmed --contract-verified
```

`--config-root`／`--config`／`--base-url` 沿用 [`helper.md`](helper.md#命令與配置)。API key 不進 CLI。沒有 report 的 `--authorized`、任意 request 或 delete 參數。flags 記錄 agent 已核對的意圖／契約，不代表 server 維護權限；預設 dry-run 不讀 credential、不連網。

## 4. 寫後核對與分開回報

HTTP 2xx 也只得到 `readback_required`。由外部 `erp` 取得該 project **完整 mapping list**，核對新增／更新 id、projectId、repo、branch、validFrom、validTo，再以相同 repo＋branch＋reportDate 的官方 resolver 核對歸屬。不只看 POST／PUT 回應或存在一筆就稱成功；更新的 modifiedTime 也從 list 留原值供後續獨立操作。

重疊、stale modifiedTime、403／缺 API、HTTP 200 應用錯誤、timeout 或不確定結果都讀回／說明並詢問下一步，不自動 retry／刪改舊列。讀回缺口記「儲存結果待確認」，不能宣稱未寫入或已完成。僅在使用者再次明確確認與 fresh 資料可用時才作新操作。

mapping 與 report 分開記錄結果；mapping 已核對成功而 report 失敗時保留 mapping、列出 report 失敗或待讀回，不做假跨端點 atomic／自動刪除回滾。所有讀回仍遵守原認證／契約停止規則。
