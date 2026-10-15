# erp-daily-work-log

將可靠每日工作證據整理成 SoftLeader ERP 本人日誌；預設先預覽再確認。`0.2.0`／MIT／sevenflankse。

## 使用

要求「把今天的工作填到 ERP」即可載入此 skill。普通工作摘要使用 `daily-work-log`。本技能依賴可發現的 `erp` 唯讀 skill 與 [`daily-work-log`](../daily-work-log/README.md)，安裝時保留整個資料夾；外部 ERP skill 不隨套件複製。

本人 context 讀取後立即核對服務端期限並分流：已知整日請假（預設 8 小時）直接停止，不蒐集、不寫；其他逾次日 10:00 情況直接 probe→預告→collect，只列工作摘要與缺口請使用者到 ERP 改，跳過覆蓋、工時、branch／mapping／module 問答及 preview。官方契約、認證、context 與上游 collector 缺口仍照規則停止。

僅未逾期路徑：當日已有日誌先確認覆蓋；「直接提交」只略過最後預覽。請假與工作合計預設 8 小時；未知工時、branch、project 或 module 先詢問。

## 0.2.0：模組與可選永久對應

- 先確認合法回報 project，再查該 project 的官方 modules；有模組的 PROJECT 含 0h 都必填。按 topic／PR／issue 選唯一有依據的候選，多義先問。不同主題可屬不同模組，寫前重查失效選項。
- 本次選 project 不等於永久儲存。另列 repo／可靠 branch／project／日期與差異，確認 save 才用 scoped mapping POST／PUT；新增預設回報日起無上界，update 兩日期明填並保留原 modifiedTime。沿用 Web 維護權限，不更新 projectId、不加 delete/upsert。
- 拒存、無維護權限或缺 mapping 寫入 API 不擋本次合法 report；衝突先問、不自動切期／改歸屬／重試。mapping／report 各自讀回、分開回報，保存後 report 失敗保留 mapping。細節見 [`references/mapping-save.md`](references/mapping-save.md)。

## Helper 與驗證

Python 3.8+、standard library，沒有新增 production dependency。helper 預設 dry-run；網路寫入是經 agent 明確判斷授權後的獨立操作。詳細輸入、外部 config 和限制見 [`references/helper.md`](references/helper.md)。每次執行以 `erp` skill 讀官方 OpenAPI，不將開發中 operation 宣稱為已部署能力。

從倉庫根目錄執行：

```powershell
python -B -m unittest discover -s skills/erp-daily-work-log/tests -v
npm run validate
```

純函式與 transport 行為測試使用合成資料／受控 network double，零真實 ERP call。agent 語意授權、來源停止、模組、日期 mapping 與讀回流程見 [`evals/evals.json`](evals/evals.json)／[執行說明及結果](evals/README.md)。本輪 8 個選定 fresh consuming-agent 合成情境符合預期，未執行完整 32 案及變體的自動 evalrunner；結構檢查、Python unit tests 與 agent 行為評估分開計算。

## 檔案

- `SKILL.md`：依序執行的流程與完成條件。
- `scripts/daily_report.py`：正式 context／detail 格式、實際 POST 工時、+08:00 期限 gate 與 scoped replace transport。
- `scripts/project_repo_mapping.py`：獨立永久儲存授權、嚴格 create／update payload，沿用 report 的 context gate、安全配置與 transport。
- `tests/test_daily_report.py`／`tests/test_project_repo_mapping.py`：行為回歸；`evals/evals.json`：agent 流程案例。
- `references/helper.md`／`references/mapping-save.md`：正式 context、plan、flags 與讀回邊界。
