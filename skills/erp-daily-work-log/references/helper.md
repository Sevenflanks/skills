# Helper：正式 context、payload 驗證與 scoped write

## 契約狀態

目前實作契約（不是部署支援聲明）：

| Operation | 用途 |
| --- | --- |
| `GET /api/v2/daily-reports/context?reportDate=yyyy-MM-dd` | 完整本人日誌、expectedSnapshot、serverNow、replaceDeadline、canReplace、PROCESS/PASS 每日假時及打卡。 |
| `POST /api/v2/daily-reports/replace` | body 為 reportDate／details／expectedSnapshot，nonempty、無舊日誌 id，全日原子替換。 |
| 官方 mapping resolve（讀 OpenAPI 選 path） | query repo／branch／reportDate 選唯一 project。 |
| 官方回報 project 選項（讀 OpenAPI 選 path） | 先確認 reportDate 的合法 project；不是 mapping 可維護清單。 |
| `GET /api/v2/daily-reports/options/projects/{projectId}/modules` | 從已確認合法 project 的清單取 module ID／label，不能用非法 project 空 list 推論無 modules。 |

執行前由 `erp` skill 讀官方 OpenAPI 及必要 schemas，核對以下實作契約、必填參照與回應語意。helper 直接驗證 context 與實際 new-detail，不執行 GET、不收集工作證據、不解析自然語言授權。部署缺 operation 或 schema 不一致時停止，不設 `--contract-verified`。

可選 mapping 維護的獨立契約／plan／flags 見 [`mapping-save.md`](mapping-save.md)；缺維護 API 只停用永久儲存。report helper 保持固定 replace，不接受 mapping operation。

## 私有 plan

保存在 repo／已安裝 skill 外的私有 task-local JSON，用後清理。`context` 直接放官方 `AjaxResponse.data` 的完整物件；外部 `erp` transport 的 envelope 依其規範取出，無須手動轉換打卡或假單：

- `reportDate`：固定 yyyy-MM-dd；`expectedSnapshot`：**預覽／確認時**的字串，不由 fresh context 覆蓋。
- `context.reportDate`：原查詢日期；`details`：當日本人完整 existing 清單；`expectedSnapshot`：fresh GET 字串；`serverNow`／`replaceDeadline`：正式 ISO timestamp，offset 必須 `+08:00`；期限固定次日 10:00，恰等於期限可寫；`canReplace`：boolean。無時區或不同 offset 均拒絕，不能猜／轉換本機時區。
- `context.leaves`：每筆 `{ "detailId": 31, "status": "PASS", "hours": 2 }`，status 僅 PROCESS／PASS；後端已排除 REJECT／CANCEL。未知狀態、重複 detailId、缺欄位或衝突停止。`leaveHours` 若提供，必須等於全部 leaves 的 hours 合計；不能用彙總值取代葉節點或填未知時數。
- `context.attendances`：保留 `{ "id": 41, "recordTime": "2026-10-14T09:00:00", "classification": "ATTENDANCE", "leaveType": null }`。`recordTime` 為同回報日、不帶 offset 的完整秒數；classification 僅 ATTENDANCE／NONATTENDANCE，前者 leaveType 為 null，後者為官方 LeaveType enum。未知分類／state／衝突停止；非出勤不直接代表任何請假時數。
- `rows`：每筆 `{ "detail": 官方 new-detail object }`；helper **只以 detail.hours 計算真正 POST 工時**，`detail.reportType == LEAVE` 算請假，其他合法分類算工作。若舊 plan 仍帶 `row.hours`／`row.kind`，必須與 detail 相等；矛盾一律拒絕，不交給 agent 自行保證。

### New-detail 最小格式

允許且僅允許 `reportType`、`hours`、`subject`、`description`、`todos`、`projectId`、`projectModuleId`、`mandateCharterId`。舊 `id`／`dailyReportId`／`reportId`、modifiedTime 或未知欄位皆拒絕，不從 existing 複製。參照欄位為 Long 整數或 null，不送 `{id}`；參照存在性、業務必填與合法關聯交給後端。

agent 仍須按主流程核對選項：有 modules 的 `PROJECT` 每列（含 0h）必填該 project 的 module ID，無 modules 才 null；寫前 recheck、失效重問。這比 ERP 現有 `hours>0` 規則嚴格，不能以 helper 不查選項為由省略。

- reportType 必填：COMPANY／PROJECT／RD／OTHER／LEAVE。
- hours 必填 JSON number：0～9999、最多 2 位小數；boolean、字串、NaN／Infinity 均拒絕。工時合计須符合總數扣假與 LEAVE 配額。
- subject 必填非空字串、最多 100；description／todos 為字串或 null、各最多 900。
- subject 與移除開頭 CR／LF 後的 description 合併不超過 1000；description 非空時計入中間一個換行。長度沿用 Java UTF-16 code units，包括 emoji。

最小私有 plan 範例（合成資料；不是已部署能力證明）：

```json
{
  "reportDate": "2026-10-14",
  "expectedSnapshot": "fixture-snapshot",
  "context": {
    "reportDate": "2026-10-14", "details": [], "expectedSnapshot": "fixture-snapshot",
    "serverNow": "2026-10-14T18:00:00+08:00",
    "replaceDeadline": "2026-10-15T10:00:00+08:00", "canReplace": true,
    "leaves": [{"detailId": 31, "status": "PROCESS", "hours": 2}], "leaveHours": 2,
    "attendances": [{"id": 41, "recordTime": "2026-10-14T09:00:00", "classification": "ATTENDANCE", "leaveType": null}]
  },
  "rows": [
    {"detail": {"reportType": "COMPANY", "hours": 6, "subject": "整理作業說明", "description": "完成欄位核對", "todos": null}},
    {"detail": {"reportType": "LEAVE", "hours": 2, "subject": "請假", "description": null, "todos": null}}
  ]
}
```

`totalHours` 可省略（8），`confirmedLeaveHours` 僅使用者明確提供請假時數才填，不是從打卡／session 推算。helper 先核對 context 服務端期限與資料格式，再按 **已知整日請假 stop → 其他 expired output_only → 未逾期 budget／rows** 的優先序分流。合法 context 中無可用假單、無打卡／非出勤且時數未知，不阻擋逾期摘要；未知 enum、錯誤格式、context 衝突仍停止。

`output_only` 不需 `rows`、已預覽的 plan.expectedSnapshot、覆蓋授權或任何 mapping；agent 跳過所有相關詢問，只依上游 probe→預告→collect 輸出可靠工作摘要及缺口，請使用者到 ERP 自行改。不發明請假／工作時數或 project/module。`stop` 不 collect；未逾期工時未知才詢問，existing 仍先問覆蓋。兩者與其他非 ready gate 都不產生 API payload、不讀 credential、不進 transport。

## 命令與配置

`<skill>` 指 runtime 發現的本技能目錄。以下 plan、config 與 deployment root 均為非 secret 路徑／設定佔位符：

```powershell
python -B "<skill>/scripts/daily_report.py" --plan "<private-plan.json>"
# 只有當次提交授權、官方 schema 核對及 fresh context gate 全通過：
python -B "<skill>/scripts/daily_report.py" --plan "<private-plan.json>" --authorized --contract-verified
# existing 另需獨立覆蓋授權：在上列命令加 --overwrite-confirmed
```

與外部 `erp` skill 共用 `<config-root>/erp/config.json`，預設 `~/.config/softleader/agent-skills/erp/config.json`。active user instructions 有 config root 時每次傳 `--config-root "<config-root>"`；明確檔案覆寫用 `--config "<config-file>"`。helper 僅讀取，不建檔或改配置。

認證使用互斥的 `apiToken` 或 `apiTokenEnv`；兩者皆無時讀 `ERP_API_TOKEN`。只送 `X-API-KEY`，沒有 token CLI 參數。API key 由使用者在外部 config/env 私下設定，不在對話索取或輸出。

若 config 已有 `baseUrl`，沿用同一部署根，例如合成 `https://erp.example.test/erp/`，不是加上 `/api/v2/` 的 operation URL。若省略，由 `erp` skill 本機 `config` 診斷取得其 project default 的 resolved baseUrl，再明確傳 `--base-url "<resolved-https-root>"`；不把部署 URL 保存到本套件。兩者同時有值而不一致拒絕。根含 backend context path，HTTPS；operation append 在同一 host/context，不允許 absolute path override、redirect、TLS 忽略或任意 method/path。

`--authorized` 是 agent 已理解本次提交授權的紀錄；`--overwrite-confirmed` 獨立記錄已有日誌覆蓋確認；`--contract-verified` 記錄實際官方 operation/schema 已核對。它們不是自然語言授權 parser、不是服務端 permission 證明。正式呼叫前再以 `erp` GET 更新 context，先重跑上述分流；`output_only` 跳過所有確認直接輸出既有蒐集摘要。仍未逾期才核對 preview snapshot，資料或工時變更需重新確認。

## 結果

- dry-run 只輸出檢查後 payload，零 credential read／network。
- HTTP 回應限制 1 MiB，default TLS 憑證驗證；禁止 redirect。錯誤只回穩定 reason，不回 reflected body、Location、原始 exception 或 credentials。
- HTTP 200 的 `messagesEmpty=false`／`ok=false`／`success=false` 視為應用錯誤；實際回應語意仍以官方 OpenAPI 解讀。任何 2xx 都只回 `readback_required`，不宣稱 business success。
- 網路不確定、snapshot conflict、應用拒絕均無 automatic retry。使用 `erp` skill 查回完整本人同日日誌核對；讀回與明細一致才完成。helper 沒有 browser、Cookie、readonly POST 或 generic write fallback。
