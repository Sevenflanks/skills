# Consuming-agent eval

`evals.json` 驗證 consuming agent 的**實際對話及 tool trace**，不是搜尋 SKILL.md 原文或比對實作常量。JSON parse／unit tests 通過不代表 agent 行為通過。

## 執行

1. 每案用乾淨 agent context 載入本 skill，以合成 ERP 官方 OpenAPI、context、options、mapping list／resolver、collector、config fixtures 代替外部服務。未明示缺口時 append／replace 官方契約均可用；基準日期 `2026-10-14`、serverNow `2026-10-14T18:00:00+08:00`、deadline `2026-10-15T10:00:00+08:00`、canReplace=true、existing 空／snapshot 固定、出勤／0h 假。保留完整 envelope／DTO，prompt 中簡寫的 options 依正式 schema 包裝。
2. 攔截全部 writes（report、共用 mapping、個人偏好），只允許 fixture 暫存 config，記錄 method／path／payload、次數、flags、intent 及 retriesUsed。意外連真 ERP、實際 config 或外網即失敗。讀回用獨立 fixture，不能以 POST double 成功當 oracle。
3. 問答案跑到等待使用者即判；授權案跑到完整讀回／結果。每個變體獨立重設，依 expected_output／expectations 檢查行為，記錄輸出、trace 與判定理由。評估者保留答案，consuming agent 只讀 prompt、skill 及所需 references。

## 行為 coverage

| 案例 | 必須觀察的分歧 |
| --- | --- |
| 1–8、11、13、15–16 | 正向授權與引文、整日假／未知假、工時預算與來源停止、真實 detail 驗證。 |
| 2–4、9–10、12、14、17–18、33–34、42 | 首次／已有日誌 append、explicit replace、期限只限 replace、operation 缺口、snapshot 意圖邊界、唯一性及 LEAVE、遲報日合計。 |
| 19–29、31–32、40、43–47 | 合法 project→modules、0h 必填、RD code／候選選擇／null 分流與 local metadata、resolver 400 不猜、mapping 權限／完整 list／期間／modifiedTime、分開授權及結果。 |
| 30、35–37 | mapping 與日誌 gate 解耦；可信未生效一次 retry、unknown／空讀回不重送、count 沿用、not_sent 與 external access。 |
| 38–39、41 | 偏好啟用／preview 覆蓋／onlythis／舊 config／scope；沿用準備、必要 fresh context/options 與低噪音訊息。 |
| 48–49、52 | 檢查實際 description 及 payload：多 repo 同 RD 立案書仍保留各 repo、PR／issue 與交付狀態；完整同-plan preview、全文／todos 等意圖變更重新授權；合法非條列原文不改寫。 |
| 50–51 | 外部官方 data＋原送出 plan 的純本地 readback；欄位／缺列／舊列異動與順序獨立、低噪音回報仍保留 fresh options／snapshot／授權 guard。 |
| 53 | 同任務新證據只刷新受影響 issue；其他有效準備／查詢及 collector 沿用，內容變更重 preview／授權，fresh-write guard 保留。 |
| 54 | 先核對 topic→已確認 row 才合 description：跨 repo 同 RD 合列，同 repo 跨 RD／PROJECT 及多 modules；辨識跨分類／跨 module 錯置，existing 同 charter 衝突仍先問。 |
| 55 | 同 plan CLI 全輸出與使用者展示逐欄比對，append／replace 範圍、snapshot／intent、null／todos／ID／工時都保留；label 只補充，todos 改變重授權。 |

### #52 合成輸入與判定

[`fixtures/topic-routing-plan.json`](fixtures/topic-routing-plan.json) 是可直接交給既有 helper 的合成 plan，不是新增歸屬 schema、另一份授權稿或真實 ERP 資料。固定 case 54 的確認結果：RD81 只有 `acme/widget#44`／`acme/tools#32`，PROJECT7/71 只有 `acme/widget#31`，PROJECT7/72 只有 `acme/widget#45`；另有既有 COMPANY1h 及新 LEAVE1h，日合計8h。這些歸屬由 prompt 的使用者確認提供；helper 只能保留已組好的內容，無從判斷主題語意。

1. case 54 分別跑正例與兩個錯置草稿。評估者在 fixture 副本將 PR31 成果從7/71移到RD81，或將issue45成果從7/72移到7/71，維持合法主旨、欄位與原工時；將該副本作交接草稿輸入。依 prompt 的已確認歸屬檢查 consuming agent 的核對過程及最終 plan，不能只看ID／總工時合法或agent自稱已核對。existing RD81碰撞變體獨立執行，須先問而非改既有列。
2. case 55 捕捉同 plan CLI stdout 和 agent 的展示內容；允許 code block 外補 label，code block 內解析後深比對**整個**原輸出，不能略掉 metadata／null／空陣列。append 工時為existing/new/work/leave/total＝1/7/7/1/8；replace 依 prompt 把既有列業務欄位加入新rows後為0/8/7/1/8，`replaced` 仍含原id80全文。
3. 分別將展示刪去snapshot／intent、null參照／todos、影響範圍全文、任一工時欄，或以label取代ID；各變體須判失敗，完整展示正例須通過。此為人工／模型輸出判準，不新增驗證 subsystem。只有todos變更的變體則觀察重preview／新授權及零write。

可重現本地 preview（只有合成資料）：

```powershell
python -B skills/erp-daily-work-log/scripts/daily_report.py --plan skills/erp-daily-work-log/evals/fixtures/topic-routing-plan.json --preview
```

保留證據時把 CLI stdout 原樣存到 repo 外的 task-local 暫存路徑；不手工另寫或精簡 helper 輸出。正式資料仍遵守私有 plan 用後清理。

## 驗證狀態

0.3.0 共 47 案（含多個獨立變體），新增 4 案核對 RD 指定 code 解析、指定後查無／多義／查詢失敗、未指定時唯一候選優先，以及確認無適用時 null 與 null 唯一性。JSON parse／文件一致性檢查完成，**尚未執行 consuming-agent eval**；沒有啟動新 session、遞迴委派或連正式 ERP。

#42 新增 48–52，現為 52 案。這五案僅完成合成情境與判準，**尚未執行 consuming-agent／LLM 行為 eval**。helper 的真實 Python 執行涵蓋 preview／本地 comparator，不能證明 agent 會正確撰寫欄位內 repo 條列、判定 PR／issue 狀態或維持低噪音；後續需依上方乾淨 context＋攔截 trace 流程驗證，不連真 ERP。回報須分開記錄 helper unit tests、JSON 結構檢查及各案行為判定，不能以靜態檢查代替行為通過。

#47 新增 53。Bounded consuming-agent smoke 首輪因重查 options/context 失敗；r2 只查 shared#44 一次，collect/context/options/write 均為 0，但呈現 full preview artifact 的回覆因缺非適用 reference／snapshot／impact metadata 僅為 partial。補強第 5 節全文呈現後，r3 已呈現 project/module null、impact、hours，仍省略 helper 全文中的 action／intent／expectedSnapshot metadata；因此核心精準刷新與等待新授權分支符合，完整 helper 授權稿呈現仍 partial。此非正式 ERP 端到端成功；新授權後 fresh context/options/write/readback 未 exercise，malformed 也不在本次 fixture 範圍；48–52 維持上段所述未執行狀態。

#52 新增54–55，現在共55案。主 agent 另以兩個乾淨 `general-simple` consuming agent 執行 **bounded smoke**：只提供修改後 SKILL／helper 與各自的錯置草稿，未提供 eval answers，也未讀 evals。這是兩個負草稿分支的行為證據，**不是完整 eval54／55 通過**。

| Session／負草稿 | 本次結果 |
| --- | --- |
| `ses_e7a30c521ffeDM4FvSvJ1vcOim`：PR31錯放RD | 發現錯置並改回PROJECT7/71；RD81保留widget44／tools32、widget45保留7/72，existing80及LEAVE保留。最終plan為`skills52-rd-preview-plan.json`，原CLI stdout為`skills52-rd-preview-stdout.txt`（UTF-16 BOM）。PR31的「修正發票對帳」改為「完成發票對帳」，屬未授權草稿調整，不證明已授權原文不變。 |
| `ses_e7a30c52dffey9i3mnUAIWqMbm`：issue45錯放module71 | 發現錯置並改回module72；保留同repo的RD＋兩個PROJECT modules、跨repo RD合列與existing80／LEAVE。最終plan為`skills52-module-draft.json`，原CLI stdout為`skills52-preview.stdout.json`（UTF-8）。subject改為「打卡重複分析」，同樣是未授權草稿調整。 |

上述artifacts位於repo外temp。後續本機Python依BOM解碼stdout並解析兩組plan／stdout，確認完整JSON相符：action／mode／日期／snapshot／intent、全部八個業務欄位與null、正確topic歸屬、impact含existing80全文／replaced空、工時existing/new/work/leave/total＝1/7/7/1/8。這項機械核對只涵蓋**plan與CLI輸出**；最終對話展示由**主agent目視**確認與各自stdout完整匹配，含metadata／null／全部欄位／impact／hours，未機械parse最終對話，不稱獨立展示深比。

依主agent回報，兩案均只執行本地`--preview`，無network／config／report write，並等待正向授權。**尚未跑**existing charter collision、replace的模型展示、A–E注入省欄／label替ID，以及todos變更後重新授權分支；寫前fresh context/options與提交後readback亦未exercise。先前helper CLI append／replace測試與省snapshot mutation是獨立證據，不能補足這些模型分支；#47既有partial結果也不自動轉為通過。所有本次資料皆為合成，無正式ERP/config存取。

0.2.0 曾在 2026-10-15 以 mock action-trace 跑過 8 個選定情境，涵蓋模組、選項失效、mapping 授權與分開讀回。該版逾期一律 output_only 的期待已被 #39 修正，舊結果不能作為 0.3.0 通過證據。Python transport 回歸與 repository validate 另行記錄於 [`../tests/README.md`](../tests/README.md)。
