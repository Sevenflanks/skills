# erp-daily-work-log

將可靠每日工作證據整理成 SoftLeader ERP 本人日誌；預設先預覽再確認。`0.1.0`／MIT／sevenflankse。

## 使用

要求「把今天的工作填到 ERP」即可載入此 skill。普通工作摘要使用 `daily-work-log`。本技能依賴可發現的 `erp` 唯讀 skill 與 [`daily-work-log`](../daily-work-log/README.md)，安裝時保留整個資料夾；外部 ERP skill 不隨套件複製。

本人 context 讀取後立即核對服務端期限並分流：已知整日請假（預設 8 小時）直接停止，不蒐集、不寫；其他逾次日 10:00 情況直接 probe→預告→collect，只列工作摘要與缺口請使用者到 ERP 改，跳過覆蓋、工時、branch／mapping／module 問答及 preview。官方契約、認證、context 與上游 collector 缺口仍照規則停止。

僅未逾期路徑：當日已有日誌先確認覆蓋；「直接提交」只略過最後預覽。請假與工作合計預設 8 小時；未知工時、branch、project 或 module 先詢問。

## Helper 與驗證

Python 3.8+、standard library，沒有新增 production dependency。helper 預設 dry-run；網路寫入是經 agent 明確判斷授權後的獨立操作。詳細輸入、外部 config 和限制見 [`references/helper.md`](references/helper.md)。每次執行以 `erp` skill 讀官方 OpenAPI，不將開發中 operation 宣稱為已部署能力。

從倉庫根目錄執行：

```powershell
python -B -m unittest discover -s skills/erp-daily-work-log/tests -v
npm run validate
```

純函式與 transport 行為測試使用合成資料／受控 network double，零真實 ERP call。agent 語意授權、來源停止、日期 mapping 與讀回流程見 [`evals/evals.json`](evals/evals.json)；eval 是待 consuming-agent 實跑的評估案例，結構驗證不等於行為評估通過。

## 檔案

- `SKILL.md`：依序執行的流程與完成條件。
- `scripts/daily_report.py`：正式 context／detail 格式、實際 POST 工時、+08:00 期限 gate 與 scoped replace transport。
- `tests/test_daily_report.py`：行為回歸；`evals/evals.json`：agent 流程案例。
- `references/helper.md`：直接使用官方 context 的 plan 範例及操作邊界。
