# ERP 工作日誌自動填寫：已確認需求

本文件是此次跨 repo 實作的需求依據；ERP 契約仍以部署環境的官方 OpenAPI 為準。

## 範圍

- 新增 `erp-daily-work-log` skill，沿用 `daily-work-log` 蒐集與摘要規則，不複製上游 skill。
- ERP 補足指定日期的本人日誌明細、請假與打卡查詢，以及期限內整天替換能力。
- 現有 repo＋branch 對應表增加日期有效期間，包含維護畫面與 migration 腳本。
- 實作階段不 commit／push；使用者後續已授權兩個 repo 分別 commit、push 並建立 PR。仍不 merge、不執行正式環境 migration，也不寫入真實 ERP 日誌。

## 填寫流程

1. 決定回報日期；預設今天、`Asia/Taipei`。所有 ERP 查詢與證據蒐集使用同一回報日期。
2. 使用 `erp` skill 的個人 API 查本人完整 context，立即核對服務端期限。已知整日請假先依第 4 點終止；其他逾期情況直接蒐集並輸出摘要，略過覆蓋、未知工時、branch／mapping／module 問答及預覽。僅未逾期時，有日誌先詢問是否覆蓋；只有當次明確要求「直接覆蓋並提交」才可省略此確認。「直接提交」本身僅略過提交前預覽確認。
3. 預設當日總工時 8 小時，包含請假。核准與審核中假單都計入；駁回與取消排除。跨日假單依 ERP 每日實際分攤，不能平均拆分或重複計入打卡。
4. 請假滿 8 小時且總工時為預設 8 小時時，直接終止，不新增請假或工作日誌。不得因 session 活動而自行添加工時。當工時被明確覆寫時，以該總工時為界；超過總工時或來源衝突需詢問。
5. 無可用假單且只有非出勤打卡時，詢問請假時數；混合出勤／非出勤且缺時數時也詢問。非出勤打卡不代表可推算全天請假時數。
6. 依 `daily-work-log` 蒐集證據。沒有可靠證據、來源全失敗或無活動時遵守上游停止規則，不湊工作內容或時數。
7. 工作工時為總工時減請假時數。以主題提出分配；合併同專案＋模組、同立案書項目，符合 ERP 單日唯一規則。partial leave 產生 LEAVE 明細，避免公開個人請假原因。
8. 以當日 repo、可靠 branch 證據及回報日期解析 mapping；未知 branch、多義、缺 mapping、必填模組或分類不明時詢問。補報當下 checkout branch 不能取代歷史 branch。
9. 未逾期時，預設先列日期、分類／專案／模組、主旨與內容、各項時數及合計，再一次確認。只有當次清楚肯定的直接提交指示可略過；引文、紀錄、否定句或較弱字眼不構成授權。
10. 超過回報日次日 10:00 時，只列蒐集結果，請使用者到 ERP 自行修改。不新增、不更新、不刪除，也不改現有逾期制度。寫入前再次檢查期限。
11. 期限內覆蓋為全刪全增，須單一交易成功或全部回滾；比較預覽時的既有資料狀態避免覆蓋預覽後變更。寫入後讀回完整日誌核對日期、項目、時數與內容；不以 exists=true 宣稱填寫完成。不確定網路結果先讀回，不自動重試寫入。

## 日期 mapping

- `validFrom`、`validTo` 是日期，兩端含當日；null 代表無該端界限。
- 同一 repo＋branch 的日期區間不得重疊；無日期的舊 mapping 保留為不限期間，不臆造切換日。
- 例如同 repo＋branch 的 CAR-Data 結束日為 2025-12-31，CAR-Other 生效日為 2026-01-01。
- resolve 必須使用回報日期。舊呼叫未帶日期時，只有唯一 mapping 可沿用；存在多期資料則要求日期，不能猜今天。
- 維護畫面延用既有 theme、共用元件與錯誤集中處理。

## 最小跨 repo 契約方向

- `GET /api/v2/daily-reports/context?reportDate=yyyy-MM-dd`：回傳本人既有日誌、狀態快照、期限與服務端時間、本人當日 PROCESS/PASS 假單每日時數及有效打卡類型。此查詢唯讀。
- `POST /api/v2/daily-reports/replace`：帶 `reportDate`、`details` 及查詢的 `expectedSnapshot`；期限內驗證本人與參照欄位，全日原子替換。空 details 不允許，禁止偽裝成唯讀 POST。
- mapping resolve 增加 `reportDate`，有效期間欄位加到 save/list/resolve schema。日期為 ISO `yyyy-MM-dd` 字串或 null；新 context 的 enum 使用 canonical string、工時使用 JSON number，保留既有 UI 的全域日期／翻譯格式。
- 上述是開發契約協調，不授權對任何部署環境呼叫；skill 執行時必須先讀官方 OpenAPI。已安裝的 `erp` helper 保持唯讀，新 skill 的 helper 僅負責經授權的日誌替換。

## 驗收

- skill catalog 與版本一致；helper 有實際行為測試，包含確認、請假、期限邊界、秘密與 redirect 保護、應用層錯誤、無自動寫入重試。
- ERP 測試涵蓋 PROCESS/PASS 與跨日分攤、本人隔離、打卡混合、替換成功／回滾／過期／快照變更及不改舊 POST 行為。
- mapping 測試涵蓋切換日、無界限、重疊拒絕、未知日、舊呼叫相容與併發衝突防護。
- 執行 skills repo 的 `npm run validate`、ERP 相關 backend 測試及 Nuxt build；只有新證據／失敗才擴大驗證。
- 目前 ERP helper 缺少本機 config；線上 OpenAPI、SSO 畫面操作與真實日誌寫入驗證尚未授權完成，不可宣稱已線上生效。

## 本次驗證紀錄（2026-10-14）

- Skills：`python -B -m unittest discover -s skills/erp-daily-work-log/tests -v`，36 個測試通過；`npm run validate` 通過，包含 path-budget 4 個、benchmark 90 個及 catalog 結構檢查。
- ERP：本次相關 15 類別共 193 個測試通過，涵蓋真實 H2 交易回滾、舊／新入口並行、期限、快照、正式 JSON mapper 與 generated OpenAPI。35 個本次變更 Java 檔的 scoped Spotless apply／check 通過。
- UI：`pnpm build` 通過；`pnpm test:nuxt test/nuxt/api-keys-project-repo-mappings.nuxt.spec.ts`，28 個測試通過。使用本機假 API 的瀏覽器驗證新增、編輯、清空日期及逆區間拒絕；不是 SSO／真後端驗收，且 mock metadata／字型仍有 console errors。
- 完整後端只執行一次：`cmd /d /c mvn.cmd -B --no-transfer-progress test -Dspotless.skip=true`，2366 tests、10 failures、69 errors、6 skipped。38 個失敗類別中未找到確定由本次變更直接造成的失敗，但沒有 base runtime 對照，不能宣稱全為既有問題。Full suite 嘗試通知、GitHub 與 SMTP 連線並失敗，沒有成功外部寫入證據。
- Standards review 沒有確認的違規；Spec review 的兩個逾期短路問題已修正並複驗。18 個 eval 中選取情境做獨立 consuming-agent 流程評估，未執行完整外部 evalrunner。正式 PostgreSQL migration、真實部署 OpenAPI／日誌寫入仍未驗證；本次實作驗證當下未 commit／push、未安裝 skill 到全域 runtime。後續 PR 發布不代表上述線上驗證已完成。
