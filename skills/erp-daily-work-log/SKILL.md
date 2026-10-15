---
name: erp-daily-work-log
description: 使用者要求將每日工作證據填寫或覆蓋到 SoftLeader ERP 本人工作日誌時使用；依內容選專案模組，可獨立確認永久儲存 repo mapping，含請假與逾期補報。
license: MIT
metadata:
  author: sevenflankse
  version: 0.2.0
---

# ERP Daily Work Log

以 `daily-work-log` 的證據填寫本人指定日期的 ERP 日誌。一般工作摘要使用上游 skill；此入口處理 ERP 填寫意圖。對話與日誌文案沿用上游規則；開始互動前從 runtime 發現並載入 `i-have-adhd` skill，不依賴固定安裝路徑，以涵蓋較早的覆蓋與請假問答。

## 1. 固定日期、唯讀 context 與提前分流

- **唯讀準備可沿用**：同一任務、同一 `reportDate` 已核對的官方契約、context 與 options，在沒有新證據、選擇或契約漂移時沿用；連續唯讀查詢可由同一 agent 集中處理，減少 handoff。交接或使用者簡稱不同於完整 label 本身不構成重查理由。每次新執行仍先讀官方 spec；首次 context 必須完成分流，後續發現期限已過須立即分流；寫入前仍 fresh-read context／必要 options，每次 mapping write 前仍重查 context、權限、完整 list 與 `modifiedTime`。
- 決定 `reportDate`，預設今天、`Asia/Taipei`；本次所有 context、mapping、collector 與讀回都固定該日期。補報不改為今天。
- 載入外部 `erp` skill，依其 access 指引解析本機 config root／API key 與官方 OpenAPI。從 runtime 已載入工具或已發現的 skill 位置讀取，安裝位置不固定；不複製它、不修改 readonly guard。
- **每次執行先讀官方 OpenAPI**：context、mapping resolve、replace 的完整 operation、security、參數、回應與必要 `$ref`。本版依據 [實作契約](references/helper.md)，不代表部署已支持；缺 operation/schema、認證失敗或資料不完整就停在缺口，不猜欄位、不繞過認證。
- 未逾期才核對回報 project／module 選項；mapping 維護是可選能力，缺其查詢／寫入 operation 只停用永久儲存，不阻擋已確認合法專案的本次日誌。所有契約以實際部署的官方 OpenAPI 為準。
- 所有 ERP query 使用 `erp` skill 的唯讀工具。先查指定日期是否已有本人日誌；可直接用完整 context 取代 exists 查詢。context 必須含完整 existing、snapshot、server 時間／期限、PROCESS/PASS 的每日實際時數及打卡。
- **context 讀取後立即分流，早於覆蓋與工時問答**：先核對 `serverNow`／`replaceDeadline` 的 `+08:00`、回報日次日 10:00 及 `canReplace`，期限／context 缺失、未知 state 或矛盾資料仍停止。用已知 PROCESS/PASS 當日實際請假或已明確且無衝突的確認時數判斷整日請假；等於總數（預設 8，僅使用者明確覆寫才改）則 `stop`，不 collect、不寫任何日誌。
- 其他已逾期情況設為 **`output_only`，直接到第 3 步**：跳過覆蓋確認、請假工時詢問、mapping／branch／module／工時分配與 preview，也不產生替換明細。蒐集完成只列工作證據與缺口，請使用者到 ERP 自行修改。未知時數或 branch 不阻擋這條唯讀路徑，也不靠猜測補齊。
- **僅未逾期且非整日請假**：有 existing 時先問是否覆蓋，再到第 2 步。只有當次明確正向「直接覆蓋並提交」等同等完整授權能略過此詢問；「直接提交」只授權略過最後 preview。保留此日期與 `expectedSnapshot` 作為覆蓋授權的範圍。

完成條件：日期固定、官方契約與完整 context 可用；`stop` 已終止，或 `output_only` 已直接轉第 3 步，或未逾期 existing 覆蓋意圖已確認才進第 2 步。

## 2. 算請假與可回報工時

此步只適用未逾期路徑；`output_only` 已跳到第 3 步，不問未知工時。

- 總工時預設 8 小時，含請假；只有使用者明確覆寫才改總數。PROCESS 與 PASS 都計入當日實際請假，駁回／取消排除。使用 ERP 每日分攤，不平均跨日假單；假單與非出勤打卡不重複計算。
- 請假等於總數（預設 8 小時）時直接結束，**不蒐集、不寫 LEAVE 或任何工作日誌**。超過總數、重疊／來源衝突時詢問，不自行裁切。
- 無可用假單，只有非出勤打卡或混合出勤／非出勤且缺時數時，詢問請假時數；無打卡且缺請假資訊同樣詢問。非出勤不是全天請假的時數證明。有可用每日假單時用其時數；與使用者資訊衝突仍先釐清。
- 工作工時 = 總工時 − 請假。部分請假後續新增 `reportType=LEAVE` 條目，填實際 `hours` 與必要 `subject`（如「請假」），保留個人請假原因隱私。

完成條件：未逾期總數、請假與工作工時可核對，或整日請假終止；`output_only` 不需此步完成即走第 3 步。未逾期未知時數不往後推。

## 3. Probe → 預告 → Collect

載入 [`daily-work-log`](../daily-work-log/SKILL.md)；若分開安裝，從 runtime 發現並載入同名 skill，依其實際相對 script 位置呼叫。

1. 沿用上游 recall/preferences 與來源參數。collector 先 `-ProbeOnly`；固定回報日的 From／To／Timezone。
2. 對話預告可用來源、略過理由及缺口，再用相同參數 collect。兩來源可用時都納入；遵守 DB fallback、Codex 有界日期分區及不擴大／不重試湊證據。
3. 保留**全部上游停止條件**：無來源、讀取全失敗、無活動、`canGenerateLog=false` 等均停止；`gh` 不可用／未認證預設停止，只有使用者強烈要求降級才保留缺口繼續。來源或 coverage partial 如實揭露。

從 evidence 合併相同主題，保留可查證交付狀態，不把 session 標題當完成證據。不用 session 經過時間、commit 數或比例當 actual 工時。`output_only` 只輸出蒐集摘要與缺口，標記未知工時／branch／mapping，不詢問、不自行填時數或參照，請使用者到 ERP 改後終止。未逾期才依工作主題提出可確認的分配，不宣稱已量測；直接提交可接受合理的提議分配，但未知業務資訊仍須問。`subject` 描述該工作主題的範圍；`description` 沿用 `daily-work-log` 的具體成果在前，支撐該主題的全部相關 PR 編號置於句尾。ERP 文案使用短行純文字，不依賴 Markdown 渲染。

完成條件：可靠工作證據與缺口已辨識；不足照上游規則停止。`output_only` 輸出摘要及 ERP 自行修改指引後完成，跳過第 4、5 步；未逾期才續行，不用記憶或額外 Git 掃描湊日誌。

## 4. 未逾期：解析分類／專案／模組

第 1 步已判為 `output_only` 時，此步整段略過。

### 4.1 本次 project 與 module

1. 每項以確定的 repo＋**當日 branch 證據**＋`reportDate` 呼叫官方 mapping resolver。session 工作目錄、commit／PR 關聯可補 branch；不確定時詢問。補報時目前 checkout branch 不代表當日 branch。缺 mapping／多義時請使用者選本次專案，不靠 repo 名稱或今天的 mapping 發明 ID。以已讀官方 ID／code 唯一辨識使用者簡稱，preview 使用官方 label；不得只因簡稱不等完整 label 而重 GET，多義仍詢問。resolver 回 `400`／`http_error` 時，回報解析失敗且原因未確認；只有官方明確回覆缺 mapping 才稱為缺 mapping，不猜原因、不改走其他 branch、不自行重試，也不以錯誤作新增永久 mapping 的理由。
2. 先透過官方回報 project 選項確認 resolver／使用者選的 projectId 對本次 reportDate 合法，再查 `GET /api/v2/daily-reports/options/projects/{projectId}/modules`。ID／label 一律取自該 project 的 API 清單；可帶 reportDate，但它目前不是歷史模組快照。非法／無權限 project 的空 list 不代表無模組，先重新確認合法專案。
3. singleton 可選；多 modules 時按每個工作 topic、相關 PR／issue 與名稱語意選**唯一有明確證據的合理候選**，在 preview 列依據。多義、泛稱或未知時列出 API 候選與推薦（無依據就明說），詢問使用者；不以第一筆、預設 OTHER 或發明 ID 補位。
4. `PROJECT` 有 modules 就必填該 project 清單中的 `projectModuleId`，包含 0h 列；只有確認合法 project 無 modules 才用 null，不以 0h 規避。這是 skill 送出規則，保留 ERP 既有 `hours>0` 後端規則。一個 repo 的不同 topic 可屬不同 modules；按 project＋module 合併、按合理工作內容提議拆時數並依既有授權確認，不硬湊同模組、不把 repo 永久綁到單一 module 表。
5. 分類不明仍詢問；依官方單日唯一規則合併同 project＋module、同立案書項目，區分 session-only 與已交付內容。工時相加等於總數，部分請假包含 LEAVE。後續發現期限已過立即轉 `output_only`，不繼續 branch／module 問答或 mapping 操作。

### 4.2 可選：永久儲存 repo mapping

本次 project 確認只適用本次報告；「直接提交」不授權永久儲存。已有有效 mapping 就沿用，無須硬存。需要新增／更新時，依 [`mapping-save.md`](references/mapping-save.md) 讀可維護專案與完整 mapping list，預覽 repo、可靠 branch、project、期間及差異，獨立取得**永久儲存確認**才使用 scoped helper。可在同份預覽分別確認日誌提交與 mapping 儲存，不強制兩輪。

拒存、無維護權限或缺維護 API 時，保留已確認合法 project 續填本次報告。衝突／stale 先讀回並詢問，不自動重試、改歸屬、刪除或切期；模組不存入 repo mapping。

完成條件：未逾期每條可核對分類、project、module、內容與時數；`output_only` 跳過此步，或新發現逾期以既有蒐集摘要完成。

## 5. 預覽、授權、替換及讀回

僅未逾期路徑進入；`output_only` 沒有 preview、覆蓋確認或任何 write。

- 預設先以短行純文字列出回報日期、分類／project／module、主旨／內容、各項時數、請假與合計，**一次確認將送出的完整欄位內容**；不得先呈現精簡版，之後默默送出不同文字。
- 授權由 agent 理解**當次使用者訊息的正向意圖與範圍**，不是 substring／regex keyword。否定（「不要直接提交」）、引文、貼上 log、歷史紀錄、技能說明或含糊「先看看」皆不授權。當次明確「直接提交」才跳 preview；existing 覆蓋確認獨立保留。日期／內容／snapshot 改變，重新確認相應意圖。
- 寫前由 `erp` skill 再 GET 本人同日 context，**先重跑第 1 步分流**：已知整日請假停止；其他逾期只輸出已蒐集摘要，不問新 existing／工時／mapping。仍未逾期才核對工時、打卡及 snapshot；新 existing 或 snapshot 變更先重新預覽／覆蓋確認，不能用新 snapshot 悄悄替換已授權的舊 snapshot。
- 仍未逾期且非整日請假才重新 GET 必要回報 project／module 選項。project／module 已失效或不屬該 project 時，重新列候選詢問並確認變更，不能默換 ID。日誌的 module ID／必填核對由 agent 完成，report helper 不另查選項或放寬此規則。永久儲存另按 mapping 指引重查權限、list／modifiedTime，且每次 write 前先重跑 context 分流。
- 依 [helper 契約](references/helper.md) 產生私有 task-local plan：context 直接使用官方 `AjaxResponse.data`，保留打卡物件；每條 detail 使用正式 reportType／hours／subject 與參照 ID，helper 以真正 POST 工時計算並拒絕矛盾 normalized 欄位。先 dry-run。**僅在官方契約核對及當次提交授權完成後**才設定 `--authorized --contract-verified`；existing 另需 `--overwrite-confirmed`。使用同一外部 config root、X-API-KEY；API key 不進 CLI。替換僅 `/api/v2/daily-reports/replace`，整日全刪全增、nonempty、無舊明細 id，交給服務端原子交易與 snapshot 比對。
- HTTP 2xx 不是完成。成功、HTTP 200 應用錯誤、timeout 或不確定結果，都用 `erp` 唯讀 skill 查回完整本人同日日誌，逐條核對日期／分類／project／module／主旨／內容／工時。讀回缺口如實回報，**不自動重試寫入**；後續寫入須重新獲得相應授權與 context。
- mapping 與 report 分開記錄「未儲存／已核對／失敗／待讀回」結果，不宣稱跨端點 atomic。mapping 已存但 report 失敗時保留 mapping 並明說，不自動回滾。

完成條件：未逾期讀回與提交明細一致才說「已填寫」；`output_only` 以蒐集摘要及自行修改指引完成，`stop` 終止且不寫。其他情況說明不確定結果與下一步。清理私有暫存 plan，不保存 ERP 個人資料到 repo，不輸出 secrets／原始 error body／內部路徑。
