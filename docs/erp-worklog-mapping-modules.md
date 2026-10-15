# ERP 日誌：確認後儲存專案 mapping 與依工作內容選模組

## 已確認範圍

- 新功能延續 `erp-daily-work-log`。原本整日請假 stop、逾期 output_only、來源不足停止、獨立覆蓋及提交授權、完整讀回與不自動重試規則均保留。
- 專案－repo mapping 是共用資料，不是本次日誌的私有選擇。API key owner 維護權限完全沿用 ERP 畫面現有 `ProjectRepoMappingService`，不把「能填日誌的所有受管專案」當成「可維護 mapping 的專案」。
- 使用者同意：可補 API-key mapping 查詢／新增／更新；新增預設 `validFrom=reportDate`、`validTo=null`。寫前列出專案、repo、可靠 branch、有效期間與新增／更新差異，取得明確的永久儲存確認。
- 單純確認本次專案、說「直接提交日誌」、引文／歷史訊息，不代表同意修改共用 mapping。確認可在同一份預覽表達兩個明確選項，不強制分兩輪詢問。
- 既有期間衝突時先列出，不自動刪除、改專案歸屬、切分或縮短舊期間。沒有維護權限或使用者不想永久儲存時，保留已確認的合法專案供本次日誌使用，不讓可選的永久儲存阻擋填報。
- 實作驗收階段只交付未提交成果；使用者後續已授權兩個 repo 分別 commit／push／開 PR，並各自完成 fresh review／必要修正至 ready。本次仍不合併、不安裝、不執行 migration、部署或真實 ERP 寫入。

## 最小 API 契約

在原 API v2／相容 Personal API 路由家族新增以下 operations；沿用 X-API-KEY 身分解析，將目前 owner 傳給既有 mapping service。Web 維護入口、角色、membership、日期區間鎖與樂觀鎖語意不變。

| Method／path（以 `/api/v2` 為前綴） | 回應／用途 |
| --- | --- |
| GET `/project-repo-mappings/projects` | `AjaxResponse<List<ProjectRepoMappingProjectView>>`，只列 owner 可維護的專案，與回報可用專案清單不同。 |
| GET `/project-repo-mappings?projectId=...` | `AjaxResponse<List<ProjectRepoMappingView>>`，查該可維護專案的 mapping，含 id、日期與 modifiedTime。 |
| POST `/project-repo-mappings` | `ProjectRepoMappingSaveRequest` → `AjaxResponse<ProjectRepoMappingView>`。projectId、repo、branch、validFrom、validTo 沿用既有欄位。 |
| PUT `/project-repo-mappings/{id}` | `ProjectRepoMappingUpdateRequest` → `AjaxResponse<ProjectRepoMappingView>`；repo、branch、日期與原 modifiedTime。不得藉 JSON 變更 projectId，原 service 不提供這項操作。 |

- 不新增 DELETE、upsert、跨專案改歸屬、批次自動切期或新權限制度；不變更資料表。
- `modifiedTime` 使用讀回的原始合法字串，不自行換時區或截精度。重疊、無權限、stale modifiedTime 由既有 service 拒絕。
- 每次從實際部署的官方 OpenAPI 選 operation／schema；不能把開發中程式視為已部署。缺 mapping 寫入 API 只停用永久儲存，已確認專案與既有回報 API 可用時仍可繼續本次日誌；不繞過 readonly ERP helper。
- 可讀取查詢皆經外部 `erp` skill；mapping 寫入由本 skill 的 scoped helper 負責。POST／PUT 明確寫入，不偽裝 readonly、不用登入 cookie。
- 寫入預設 dry-run，必須有永久 mapping 確認及官方契約核對；共享既有安全 transport／config，保留 HTTPS、阻止 redirect、去敏錯誤及無自動重試。寫後依完整 mapping list／resolver 讀回確認 id、專案、repo、branch、期間，而非只看 HTTP 2xx。
- mapping 儲存和日誌替換是兩個獨立結果，不宣稱跨端點交易：mapping 已存但日誌未完成時如實報告，不自動刪 mapping 回滾。

## 模組選擇流程

1. 固定 `reportDate`，先依既有 context 判斷 stop／output_only。這兩條路徑不得因新增功能查模組或寫 mapping。
2. 未逾期時透過官方回報專案選項確認 projectId；以 repo＋有證據的當日 branch＋reportDate 解析 mapping。必要時由使用者確認本次專案，再獨立選擇是否永久儲存。
3. 對本次各 `PROJECT` 專案使用既有 `GET /api/v2/daily-reports/options/projects/{projectId}/modules`，依官方 schema 取得 id／label。可帶 reportDate，但它目前不讓模組清單變成歷史快照。先確認專案合法，不能把無權限／非受管專案所產生的空清單誤當「沒有模組」。
4. 僅從該專案回傳清單選模組。唯一模組可直接選；多模組時依工作內容、相關 PR／issue 與名稱語意選唯一有明確依據的候選，預覽列出選擇依據。多個合理候選、泛稱或證據不足時，列候選與推薦請使用者選，不以數量排序、第一筆或「其他」硬配。
5. 有模組的專案，skill 送出前必須填該專案清單中的模組 ID；無模組才可 null。這是 skill 的送出規則，不修改 ERP 現有 `hours>0` 才強制模組的舊規則；也不以建立零時數列規避選擇。

一個 repo 可能同時涉及多個模組。依工作主題分配，再依同 project＋module 合併日誌；需要跨模組拆分時提出工時分配並按既有授權確認。模組不永久存入 repo mapping 表、不新增 module mapping schema 或 AI 信心分數資料庫。寫前重新查必要選項；已失效／不屬專案的模組重新選擇，不能默默換成別的 ID。

## 必要驗證

- ERP：新 operations 的本人身分、非成員／一般成員／DEV／MGR／PM 維護權限與既有畫面一致；report 可用不代表 mapping 可維護。日期有效區間、期間重疊、modifiedTime 衝突拒絕且資料不變；正式 mapper／OpenAPI 路由、schema、JSON 契約，無新增 DELETE。
- Skill：scoped helper dry-run、獨立 mapping 確認、契約缺口、未知 method／path／ID、stale update、不重試、錯誤不洩密；原日誌 37 tests 不回歸。新增模組／永久儲存 consuming-agent eval，驗證多義詢問、合法模組必填、手動專案但不存 mapping 仍能填報、已逾期零 mapping/module/write，以及保存與日誌結果分開報告。
- 修改 catalog／skill version 時同步各 entry。執行 `npm run validate`，後端最小相關 tests 與適用 checks；不以結構檢查當 consuming-agent 完整行為評估。

## 實作與驗證（2026-10-15）

- ERP 已補四個 mapping operations；直接重用 authenticated owner 與既有 Web service，未修改角色／membership、資料表、日誌模組舊規則或 UI。新增八個真 service／合成 H2／正式 mapper 整合測試；scoped 126 tests、五個 touched Java 的 Spotless check 及 `git diff --check` 通過。
- 完整後端只執行一次：`cmd /d /c mvn.cmd -B --no-transfer-progress test -Dspotless.skip=true`，Maven 3.9.11／Corretto 25.0.1，**2,373 tests、0 failures、0 errors、10 skipped**。PG／live opt-in 未啟用，skipped 不等於正式 PostgreSQL 或 live 驗證通過；本輪未實跑 CI Java 11。
- Skill 版本 `0.2.0`，catalog 同步。新增 mapping scoped helper；只支援固定 POST／PUT、獨立永久儲存確認，與 report 共用 context gate／安全 transport，原 37 個 report tests 保留。最後 `python -B -m unittest discover -s skills/erp-daily-work-log/tests -v` 為 **51 tests passed**；實跑 Python 3.12.0，原 strict Python 3.8 parser double 保留，但未實跑 3.8 runtime。
- `npm.cmd run validate` 通過：4 個 path-budget tests、90 個 benchmark tests 與 skill／catalog／metadata 檢查。兩個 worktree 的 `git diff --check` 通過。
- 獨立 Standards／Spec review 無 must-fix。Spec 指出 helper／範例容許空白＋秒格式，但正式 readback 為 ISO `T`；本輪將 helper、合成測試、reference 與 eval 28 收斂至真正可 roundtrip 的 ISO 格式，保留原 timestamp 精度，RED→GREEN，獨立複核已解。未擴張後端 legacy 日期契約。
- 選定 **8 個** fresh consuming-agent 合成情境符合預期，包含多主題模組、0h 不繞過、寫前選項失效、僅本次不存、永久儲存獨立確認、逾期零操作、mapping 與 report 獨立結果、無維護權仍可回報；詳見 skill 的 `evals/README.md`。不是完整 32 案及變體的自動 evalrunner。
- 所有驗證 process 已結束，無本輪常駐程序。以上為實作驗收時的證據；後續交付沿用兩個隔離 worktree 與未受影響的驗證，PR head、review 與 checks 以各 PR 最新讀回為準。**未合併／安裝，未部署、執行 migration 或寫入真實 ERP**。線上 OpenAPI／新 API 部署、正式維護權限與真實寫入仍未驗證；執行時以官方契約決定能力，不能把本機通過視為已上線。
