# Helper：正式 context、payload 驗證與 scoped write

## 契約狀態

目前實作契約（不是部署支援聲明）：

| Operation | 用途 |
| --- | --- |
| `GET /api/v2/daily-reports/context?reportDate=yyyy-MM-dd` | 完整本人日誌、expectedSnapshot、serverNow、replaceDeadline、canReplace、PROCESS/PASS 每日假時及打卡。 |
| `POST /api/v2/daily-reports` | append：body 為 reportDate／details，只送新列，不帶 id／modifiedTime／expectedSnapshot。 |
| `POST /api/v2/daily-reports/replace` | body 為 reportDate／details／expectedSnapshot，nonempty、無舊日誌 id，全日原子替換。 |
| 官方 mapping resolve（讀 OpenAPI 選 path） | query repo／branch／reportDate 選唯一 project。 |
| 官方回報 project 選項（讀 OpenAPI 選 path） | 先確認 reportDate 的合法 project；不是 mapping 可維護清單。 |
| `GET /api/v2/daily-reports/options/projects/{projectId}/modules` | 從已確認合法 project 的清單取 module ID／label，不能用非法 project 空 list 推論無 modules。 |
| 官方 RD 立案書 options（讀 OpenAPI 選 path） | 依本次需求核對 reportDate 的適用 mandateCharterId；API 欄位可選不代表跳過解析。 |

執行前由 `erp` skill 讀官方 OpenAPI 及必要 schemas，核對以下實作契約、必填參照與回應語意。helper 直接驗證 context 與實際 new-detail，不執行 GET、不收集工作證據、不解析自然語言授權。部署缺 operation 或 schema 不一致時停止，不設 `--contract-verified`。

可選 mapping 維護的獨立契約／plan／flags 見 [`mapping-save.md`](mapping-save.md)；缺維護 API 只停用永久儲存。report helper 僅按 `mode` 選固定 append／replace，不接受 mapping operation 或任意 endpoint。個人偏好的啟用、作用範圍、儲存 API 見 [`preferences.md`](preferences.md)，不放入 report payload。

## 私有 plan

保存在 repo／已安裝 skill 外的私有 task-local JSON，用後清理。`context` 直接放官方 `AjaxResponse.data` 的完整物件；外部 `erp` transport 的 envelope 依其規範取出，無須手動轉換打卡或假單：

- `reportDate`：固定 yyyy-MM-dd；`expectedSnapshot`：**預覽／確認時**的字串，不由 fresh context 覆蓋。
- `mode`：`append` 或 `replace`，省略維持舊版 replace 相容；agent 首次填寫／補新增須明填 append。append 的 plan.expectedSnapshot 仍與 fresh context 比對，但不送 server，只防止偷換已預覽意圖；不是 server CAS、idempotency key 或 empty-day atomic check。
- `context.reportDate`：原查詢日期；`details`：當日本人完整 existing 清單；`expectedSnapshot`：fresh GET 字串；`serverNow`／`replaceDeadline`：正式 ISO timestamp，offset 必須 `+08:00`；期限固定次日 10:00，恰等於期限可寫；`canReplace`：boolean。無時區或不同 offset 均拒絕，不能猜／轉換本機時區。
- `context.leaves`：每筆 `{ "detailId": 31, "status": "PASS", "hours": 2 }`，status 僅 PROCESS／PASS；後端已排除 REJECT／CANCEL。未知狀態、重複 detailId、缺欄位或衝突停止。`leaveHours` 若提供，必須等於全部 leaves 的 hours 合計；不能用彙總值取代葉節點或填未知時數。
- `context.attendances`：保留 `{ "id": 41, "recordTime": "2026-10-14T09:00:00", "classification": "ATTENDANCE", "leaveType": null }`。`recordTime` 為同回報日、不帶 offset 的完整秒數；classification 僅 ATTENDANCE／NONATTENDANCE，前者 leaveType 為 null，後者為官方 LeaveType enum。未知分類／state／衝突停止；非出勤不直接代表任何請假時數。
- `rows`：每筆 `{ "detail": 官方 new-detail object }`；RD 列另須帶 local 必填 `expectedMandateCharterId`（Long ID 或明確 `null`）。這是 agent 已完成官方選項判斷的本地預期值，不是 detail/server 欄位，也不會送到 ERP。有效 ID 時 `detail.mandateCharterId` 必須相同；預期為 null 時 detail 可省略或為 null，不能帶 ID。缺 key 代表選擇未完成、拒絕送出；非 RD 不得帶此 metadata。helper **只以 detail.hours 計算真正 POST 工時**，`detail.reportType == LEAVE` 算請假，其他合法分類算工作。若舊 plan 仍帶 `row.hours`／`row.kind`，必須與 detail 相等；矛盾一律拒絕，不交給 agent 自行保證。

### New-detail 最小格式

允許且僅允許 `reportType`、`hours`、`subject`、`description`、`todos`、`projectId`、`projectModuleId`、`mandateCharterId`。舊 `id`／`dailyReportId`／`reportId`、modifiedTime 或未知欄位皆拒絕，不從 existing 複製。參照欄位為 Long 整數或 null，不送 `{id}`；PROJECT 必填 projectId。RD 的 `mandateCharterId` 依部署官方 schema 可選；若 detail 帶值，必須是核實的 Long ID。helper 只驗格式及下述 local metadata 一致性，agent 須先按當次需求用官方 options/resolver 核對參照及適用性，不能將選擇缺口交給 HTTP 500。

### RD 選擇與 local metadata

每次新任務仍先核對部署官方 spec 與當日立案書 options。user 指定 code 時，用官方 options/resolver 解析出相符 ID；查無、多義或查詢失敗先修正／詢問，不能以 null 繞過。user 未指定時，若有唯一明確適用候選，優先選它；只有確認沒有適用立案書才用 null。不得把 user 指定要求擴大成所有 RD 都須由 user 指定。

每筆新 RD row 的 local `expectedMandateCharterId` 是必填選擇紀錄：Long 表示已選定 ID，明確 null 表示 agent 已按官方 options 確認無適用立案書；missing key 表示尚未完成選擇，拒絕送出。detail 的有效 ID 必須和 local 預期相同；預期 null 時 detail 可省略或為 null，不得帶 ID。此 metadata 不放進 detail、不屬 server 欄位、不發送 ERP。非 RD row 不可帶它。existing RD detail 沒有這項 local metadata 仍可讀；existing null 不與其他 null 觸發同立案書唯一性衝突，existing 非 null ID 仍依既有規則先詢問衝突。

agent 仍須按主流程核對選項：先合法 project，再查其 modules；有 modules 的 PROJECT 每列（含 0h）必填該 project 的 module ID，無 modules 才 null；RD 依本次需求核對當日官方立案書 options。寫前 recheck、失效重問，不能以 helper 不查選項或個人偏好為由省略。

- reportType 必填：COMPANY／PROJECT／RD／OTHER／LEAVE。
- hours 必填 JSON number：0～9999、最多 2 位小數；boolean、字串、NaN／Infinity 均拒絕。replace 只加 new rows；append 加 existing＋new，合計工作／LEAVE 須符合總數扣假與請假配額。append 不重送既有 LEAVE，遇到 `existing_leave_conflict` 或 project＋module／RD 單日唯一性衝突 `daily_uniqueness_conflict` 回 ask，先詢問、不改舊列或默默換歸屬。
- subject 必填非空字串、最多 100；description／todos 為字串或 null、各最多 900。
- subject 與移除開頭 CR／LF 後的 description 合併不超過 1000；description 非空時計入中間一個換行。長度沿用 Java UTF-16 code units，包括 emoji。

最小私有 plan 範例（合成資料；不是已部署能力證明）：

```json
{
  "mode": "append",
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

此例 append 的實際 POST body 只有 `reportDate` 與 `details`（6h COMPANY＋2h LEAVE）；plan.expectedSnapshot 不進 body。改 mode=replace 才在 POST body 加 expectedSnapshot。

`totalHours` 可省略（8），`confirmedLeaveHours` 僅使用者明確提供請假時數才填。helper 仍驗 context 時間／state 格式，先已知整日假 stop；**只有 replace** expired 才 output_only，append 即使 canReplace=false 仍驗 budget／rows。append 未知請假先 ask。未知 enum、錯誤格式、資料衝突仍拒絕。

逾期 append 不代表豁免：agent 仍遵守官方工作日／遲報／豁免及非豁免日總數至少 8h（含 existing）的規則。context 沒有 holiday／exemption 欄位，helper 的自訂預算不是 server eligibility 證明；沒有官方資訊時揭露必要條件並交 server validation，不猜假日／豁免、不發明時數。

`output_only` 不需 rows、預覽 snapshot 或覆蓋授權，依上游 probe→預告→collect 輸出可靠摘要與缺口，不發明時數／參照；`stop` 不 collect。agent 另可在所需 operation 不可用時選 output_only，不將它誤用於合法 append。所有非 ready gate 均不產生 API payload、不讀 credential、不進 transport。獨立 mapping 維護不套此 gate。

## 命令與配置

`<skill>` 指 runtime 發現的本技能目錄。以下 plan、config 與 deployment root 均為非 secret 路徑／設定佔位符：

```powershell
python -B "<skill>/scripts/daily_report.py" --plan "<private-plan.json>"
# 只有當次提交授權、官方 schema 核對及 fresh context gate 全通過：
python -B "<skill>/scripts/daily_report.py" --plan "<private-plan.json>" --authorized --contract-verified
# 僅 replace existing 另需 --overwrite-confirmed；append 保留 existing、不需要覆蓋授權
```

與外部 `erp` skill 共用 `<config-root>/erp/config.json`，預設 `~/.config/softleader/agent-skills/erp/config.json`。active user instructions 有 config root 時每次傳 `--config-root "<config-root>"`；明確檔案覆寫用 `--config "<config-file>"`。helper 僅讀取，不建檔或改配置。

認證使用互斥的 `apiToken` 或 `apiTokenEnv`；兩者皆無時讀 `ERP_API_TOKEN`。只送 `X-API-KEY`，沒有 token CLI 參數。API key 由使用者在外部 config/env 私下設定，不在對話索取或輸出。

若 config 已有 `baseUrl`，沿用同一部署根，例如合成 `https://erp.example.test/erp/`，不是加上 `/api/v2/` 的 operation URL。若省略，由 `erp` skill 本機 `config` 診斷取得其 project default 的 resolved baseUrl，再明確傳 `--base-url "<resolved-https-root>"`；不把部署 URL 保存到本套件。兩者同時有值而不一致拒絕。根含 backend context path，HTTPS；operation append 在同一 host/context，不允許 absolute path override、redirect、TLS 忽略或任意 method/path。

`--authorized` 是 agent 已理解本次提交授權的紀錄；`--overwrite-confirmed` 只供 replace existing；`--contract-verified` 記錄實際官方 operation/schema 已核對。它們不是自然語言授權 parser 或 server permission 證明。正式呼叫前以 `erp` GET fresh context 及必要 options，重跑所選 mode 分流並核對 preview snapshot；日期／內容／歸屬／snapshot 變更須重新預覽／確認，不能把新值塞進舊授權。

## 一次受控 retry

dry-run 回傳 payload 與 `intent`，intent 涵蓋 mode、完整 payload 及 context snapshot。保留原 dry-run intent、授權與每次返回的 retriesUsed；不是 server idempotency／持久重試紀錄。`execute` 每次最多送一個 request，不在 transport 內 retry。

傳輸前配置／驗證失敗，CLI 回 `requestState=not_sent`，修正後可續作。傳輸後出錯回 `requestState=unknown`、`retriesUsed`，一律先讀回；成功 transport 亦只回 readback_required、intent、retriesUsed（首次 0、retry 1）。caller 必須沿用 count，不能用舊 plan 重新歸零。

只有可信證據確認先前請求**未生效且不會稍後提交**，才可在相同意圖、fresh context／必要 options 仍吻合且原授權有效時使用：

```json
{"retry":{"outcome":"definitely_not_applied","trusted":true,"evidence":"可信未生效摘要","retriesUsed":0,"originalIntent":"原 dry-run intent"}}
```

將 retry 物件加入原 plan；evidence 是 agent 核對後的去敏摘要，不是把 HTTP 500 或空讀回包裝成可信證明。outcome=applied 回 stop；unknown／timeout／empty_readback 等一律 readback_required，零送出；缺可信證據回 ask。retriesUsed 非 0 或 intent（含 snapshot）不同回 ask，須重新 preview／取得相應授權。新內容不屬舊授權重試。

## 結果

- dry-run 輸出檢查後 payload 與 intent，零 credential read／network。
- HTTP 回應限制 1 MiB，default TLS 憑證驗證；禁止 redirect。錯誤只回穩定 reason，不回 reflected body、Location、原始 exception 或 credentials。
- HTTP 200 的 `messagesEmpty=false`／`ok=false`／`success=false` 視為應用錯誤；實際回應語意仍以官方 OpenAPI 解讀。任何 2xx 都只回 `readback_required`，不宣稱 business success。
- 網路不確定、snapshot conflict、應用拒絕不盲目 retry；僅上述可信未生效情境可一次受控重試。用 `erp` 完整讀回逐條核對日期、分類、參照、主旨、內容及工時，append 亦核對 existing 未被改寫，吻合才完成。單次空讀回不能證明在途請求不會提交。helper 沒有 browser、Cookie、readonly POST 或 generic write fallback。
