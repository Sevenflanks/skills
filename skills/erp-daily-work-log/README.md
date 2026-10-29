# erp-daily-work-log

將可靠每日工作證據整理成 SoftLeader ERP 本人日誌；預設先預覽再確認。`0.4.2`／MIT／sevenflankse。

## 使用

要求「把今天的工作填到 ERP」或「補新增昨日 ERP 日誌」即可載入。一般摘要使用 `daily-work-log`。安裝時保留整個資料夾，依賴 runtime 可發現的外部 `erp` 唯讀 skill 與 [`daily-work-log`](../daily-work-log/README.md)；不複製外部 ERP skill。

1. 固定日期並讀部署官方契約與完整本人 context。已知整日請假（總數預設 8h）停止，不蒐集、不寫日誌；未知請假／衝突先釐清。
2. 首次填寫、補新增用官方 append，已有日誌仍追加；僅使用者明確替換時走 replace，獨立確認覆蓋。只有 replace 受次日 10:00 期限限制；所需 operation 不可用或 replace 逾期時，仍可 probe→預告→collect 輸出可靠摘要與缺口。
3. 在確認的工作預算內自行提出合理主題分配，不逐項詢問、不冒充實測工時；呈現完整欄位全文並取得授權後送出，最後逐條讀回核對。當次直接提交可省 preview，不能省合法 options、必要未知資訊及 fresh-write context 核對。

官方契約、認證、未知 state、必要資料與 collector 停止規則始終適用。主題選定後、完整 ERP preview 前，依 [`daily-work-log`](../daily-work-log/SKILL.md) 補查影響成果／待辦的明確引用 issue；有效準備可續用，失效時只刷新受影響項。只回報新發現及必要問題，減少重複 Checking 訊息；若補證改變日誌內容／意圖，才更新完整 preview 並重新授權。寫前 fresh context/options 與完整讀回照常保留。

## 0.4.2：歸屬核對與完整預覽

先核對每個證據主題的已確認歸屬，再合併列描述；同 repo 的多 module／分類仍合法。授權時直接展示同 plan 的完整 helper 輸出，保留 snapshot／intent、null、影響範圍及工時；不新增平行授權稿或改寫 helper。

## 0.3.0：補新增、受控重試與偏好

- **append／replace 分流**：append 只送新列、無 id／modifiedTime／expectedSnapshot，合計含 existing，不改舊列、不重複 LEAVE；撞到 project＋module 或同一非 null RD 立案書的單日唯一性先問。plan snapshot 保護本地 preview 意圖，不是 server CAS 或寫入時空日原子保證。逾期新增仍遵守官方工作日／豁免及日合計至少 8h 規則；無官方假日／豁免資訊不猜放行，揭露條件並交 server validation。
- **一次受控 retry**：本地配置／驗證失敗是 not_sent；傳輸後先讀回，已生效停止，unknown／timeout／單次空讀回不重送。只有可信未生效證據、相同原 intent（含 snapshot）、原授權與額度有效時可重試一次，每次最多一個 request，caller 沿用 count。詳見 [`helper.md`](references/helper.md)。
- **偏好與合法參照**：先確認啟用一次，已啟用後 preview 新選擇預設覆蓋對應範圍，「僅本次」不存；保留 config 其他 keys。依 [`preferences.md`](references/preferences.md) 的 namespace／API 處理。偏好不取代每次新任務的官方 spec／options 核對。有 modules 的 PROJECT 含 0h 都必填；RD API 欄位雖可選，user 指定 code 必須解析正確 ID，未指定時唯一明確適用候選優先選用，只有確認無適用才可選 null。查無、多義或查詢失敗先處理，不能以 null 繞過。new RD row 的 local `expectedMandateCharterId` 必須明確記錄選定 ID 或已核實的 null，且不送 ERP；詳見 [`helper.md`](references/helper.md)。
- **獨立 mapping 維護**：共用 repo mapping 與個人偏好、日誌提交分別授權；不套日誌 deadline／全天假／未知請假 gate。仍須每次重查維護權限、完整 list、有效期間、modifiedTime，預覽差異並獨立確認。module 不入 mapping；不新增 delete/upsert、不宣稱跨端點 atomic。詳見 [`mapping-save.md`](references/mapping-save.md)。

## Helper 與驗證

Python standard library，無 production dependency；CI 使用 Python 3.12。helper 預設 dry-run，正式寫入需 agent 理解當次授權及官方契約。日期、payload、外部 access 與操作限制見 [`helper.md`](references/helper.md)。resolved base URL 沿用外部 ERP access，不猜部署，API key 不進 CLI 或輸出；個人資料 plan 留在 repo 外，用後清理。

組稿先逐主題核對已確認分類／參照及所屬 row，再合併 `description`；同 repo 可合法分多 modules 或分類。實際 `description` 預設採 repo 群組行＋短行純文字條列，保留 PR／issue 與核實交付狀態；同一 RD 立案書合併後仍保留各 repo。直接展示同一 plan 的 helper `--preview` 完整輸出，包含 snapshot／intent、全部業務欄位及 null、影響範圍全文與工時；官方 label 另作補充。由外部 `erp` 取得完整官方 data 後，`--readback` 純本地比對原 plan 的新舊列、全文與 todos，不依列排序。兩者不讀 credential／呼叫 API；helper 保留合法非條列原文，不改寫已授權文案。命令及限制見 [`helper.md`](references/helper.md#本地-preview-與-readback)。

從 repo 根執行：

```powershell
npm run test:erp-daily-work-log
npm run validate
```

`validate` 已接 Python unittest discover；CI 設好 Python 後執行同一條 validate，不重複跑 ERP tests。unit tests 只用合成資料、暫存 config 與 fake transport，零正式 ERP call。agent 語意行為使用 [`evals/evals.json`](evals/evals.json)，執行狀態見 [`evals/README.md`](evals/README.md)，不能把 JSON 結構通過算作行為 eval 通過。`0.4.1` 沿用 upstream 的精確 canonical repo／issue 狀態補證規則；若新狀態改變日誌內容，仍須重新 preview 並取得授權。

## 維護入口

- `SKILL.md`：按操作分流的流程及完成條件。
- `scripts/daily_report.py`：正式 context／detail、完整 preview／本地 readback、append／replace、intent／retry 與 scoped transport。
- `scripts/project_repo_mapping.py`：獨立日期／shape 驗證與 scoped create／update，維護權限及完整 list 核對由 agent 執行。
- [`tests/README.md`](tests/README.md)：測試 seam、red→green 與 mutation list；`references/`：按分支載入的 plan／授權／偏好契約。
