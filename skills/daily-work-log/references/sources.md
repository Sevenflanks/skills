# 來源選擇與共用證據契約

## 當次來源

| EvidenceSource | 行為 |
| --- | --- |
| github（預設） | 報告日 merged PR＋本人新建規格 Issue；Git 只辨識 remote／worktree，不讀 commit history 或 Session |
| session（明確指定） | 原 OpenCode／Codex、Git／GitHub 補證及所有有界能力 |
| combined（明確指定） | 同日讀取前兩者；保留 Session coverage，依 canonical identity 合組 repo，語意主題由 agent 整理 |

`SourceMode=session/scan/mixed` 保留 repo 探索語意，預設 session；不據此切換 EvidenceSource。`To` 統一為 exclusive；原 Session adapters 的 inclusive upper bound 由 caller 轉成 To−1 tick，adapter 本身的讀取限制與能力不改。舊腳本若填當天 23:59:59，請改次日 00:00 以涵蓋完整一天。舊來源偏好不覆蓋 GitHub 新預設，其他範圍／ERP 偏好保留，本任務不新增永久設定。歷史、引文、單純說到 session 不構成指示。GitHub 空／失敗只揭露狀態與可明確選擇的替代來源，不自動切換。

沿用公開 `capture-daily-work-log.ps1 -Mode probe/collect/format`；JSON 參數新增：

```json
{"EvidenceSource":"github","Repositories":["owner/repo"],"ProxyLogins":["confirmed-agent[bot]"],"GitHubInputPath":"<private-task-response-capture.json>","ManualInputPath":"<private-task-manual.json>","From":"2026-11-16T00:00:00+08:00","To":"2026-11-17T00:00:00+08:00","Timezone":"Asia/Taipei"}
```

Repositories、ProxyLogins、兩個 InputPath 均可省略。ProxyLogins 只傳當次已有可靠身分對應的代理 login，不從姓名猜、不寫死任何人；仍須 PR→本人需求／派工的關聯證據才能成立。Repositories 用可靠 canonical repo；不傳時先從 viewer 活動發現 repo，僅在確認的本機／Session repo 補查代理成果，不掃全組織。範圍偏好及使用者 repo／scan roots 先帶入，不固定試跑清單。

## Provider：connector 優先，共用規則

使用環境已提供且足夠的 GitHub connector。若它能提供目前身分、搜尋與精確資源，將**同輪原始回應**寫到 repo 外私有 `GitHubInputPath`；collector 的 connector capture 與 gh 共用同一套 query／日期／本人／去重邏輯。capture 缺回應是失敗，不退回 gh，不接受預先分類的「本人成果」冒充 GitHub 回應。connector 不足時才沿用 gh 入口，明說實際 provider／缺口；認證失效遵守既有明確降級規則，不能悄悄改用未登入範圍。

Provider capture 是 JSON object：`responses` array，每筆為 `{path, parameters, response, status?}`。path 不含前導 `/`；parameters 是 API query object，無參數填 `{}`；response 是該 endpoint 的完整官方 JSON，status 預設 200。每個精確 path＋parameters 只能一筆。`user` 的 response 需 connector 已核實的 viewer 物件（至少 login），來源身分必須是當前帳號，不能用 repo owner 代替。capture 保存於當次私有暫存，不是跨任務 cache。

用同一份參數與以下 query 取得回應，缺項補到**同份 task capture**再正式 collect，不為摘要／ERP 重抓已成功資料：

1. `user`，parameters `{}`：當前 viewer。
2. `search/issues`，parameters `{q,per_page:100,page:1}` 起逐頁取。候選日期為 From 的 UTC 日期至 To 的 UTC 日期＋1 天（寬定位），正式入口仍重新核對事件與半開區間。單一 repo 的 PR query 是 `repo:owner/repo is:pr is:merged merged:YYYY-MM-DD..YYYY-MM-DD`；Issue query 是 `repo:owner/repo is:issue author:viewer created:YYYY-MM-DD..YYYY-MM-DD`。未指定 repo 的本人搜尋移除 repo qualifier 並加入 `author:viewer`；已確認 repo 才補查代理 PR。保留官方 total_count／incomplete_results。最多 10 頁，空頁但尚未達 total、搜尋限制及未完整結果均為 partial。
3. 每個候選 `repos/owner/repo/pulls/N` 或 `repos/owner/repo/issues/N`：保留完整官方 body、author、事件時間、URL、state、head/base 等欄位。以 canonical repo＋類型＋編號核對回應，搜尋結果本身不證明 merged。
4. 只讀會影響歸屬／驗收／待辦的精確關聯 Issue。PR body 的 closing／Refs／Part of 與完整 Issue URL 形成關聯，不證明已 CLOSED。必要補讀留言或 native parent 關聯時，由 agent 使用同輪 provider 並保留原始 URL／作者／觀察時間；無可靠身分證據列 pending，不猜。

CLI live provider 使用 `gh api` 執行同一組 endpoint。gh 缺失不代表 connector 不可用；probe 只檢查已指定 capture／CLI 入口，不執行認證或搜尋。正式 collect 才核對 viewer。stdout 始終純 JSON，capture 不回顯 raw；錯誤只留安全代碼，不反射 response body 或內部路徑。

## 日期、本人與主題

預設 Asia/Taipei，From 含、To 不含。公開入口共用既有 System.TimeZoneInfo 固定範圍；Python 沒有 IANA DB 時沿用 native offset 與每個手動日期的獨立 offset，跨 DST 不用起日 offset 猜全部日期，也不安裝 tzdata。PR 入口看 mergedAt／官方 merged_at，新規格 Issue 看 createdAt／created_at，updatedAt 不構成當日工作。補報分開 reportEventAt 與 stateObservedAt；規格發布、已合併、部署與真實驗收是不同狀態。Issue 作者與內容是候選；agent 依可辨識需求、範圍或驗收判斷，不強制 label 或標題模板。

本人 PR 是 author=viewer，或當次已確認代理 login 且有本人需求／派工關聯。僅 merged-by、assignee、reviewer、同 repo、姓名或相似標題不夠；pendingAttribution 需合併釐清，不能直接入稿。例行 release／deploy／升版還要可辨識的本人實際工作關聯。代理代開未合併規格若缺本人建立證據只保留候選，不冒充本人新建。

collector 以 canonical repo＋type＋number 去重原始項目，保留 issues、prs、manualEvidence、sessionEvidence 及代理依據。agent 依**實質主題與已確認 ERP 歸屬**合併規格、父子票、PR、Session 與手動內容，保留全部支撐編號；獨立人工驗收、不同工作或不同歸屬分開。缺 branch 只釐清必要歸屬；不以現在 checkout 猜補報 branch，也不建立不完整偏好／mapping。

## 手動內容

ManualInputPath 為使用者提供工作的 array：

```json
[{"date":"2026-11-16","repo":"owner/repo","result":"完成本機原型與 SQL 打包核對","todos":["正式環境驗收"]},{"date":"2026-11-16","project":"維運","result":"處理非 git 環境操作查核","todos":[]}]
```

date、非空 result 必填；repo／project 可缺，先保留待確認專案。純日期依報告時區解讀，範圍外不入稿。原文及 todos 保留，標示 user-provided／verifiedByGitHub=false；不要求先製造 Issue。三種模式皆可帶入，手動-only 不被自動來源空結果 gate 阻擋。與自動證據重疊由 agent 去重，不重複分配工時。

## 視圖、診斷及 ERP

先 bounded index，再按 repo／session／原始 raw pointer 選讀；完整 ERP view 保留新 Issue、手動內容、歸屬依據及全文。unknown／partial／failed／empty／not-selected 分開。github coverage 保留 pages／limitHits／failures；requests 是私有 raw 的外部 request 記錄，index 不展開。Session 原日期／身分／scope 狀態另保留在 meta.sessionContext；有指定 Repositories 時 Session 也套用相同 canonical 範圍，未能識別的資料私下保留在 unresolvedRepositories，以 scopeUnresolved／警告揭露，不猜歸屬。Session diagnostics 保留在 composition diagnostics.session，totalDurationMs 是獨立 wall，重疊 stages 不相加。

composition 的六 stage 記錄實際執行與失敗：sourceAdapter 是 provider／manual capture 的檔案讀取；json 是 bridge request、capture 或 live response 的解析；repoDiscovery 是 canonical repo 探索；git 是 remote 子程序；github 是 provider request（cacheHits 另計，不增加 calls）；output 是主 JSON 序列化，結束後才補小型診斷並寫 stdout。probe 未進入的來源／探索／git／github 保持 null；已執行但零次外部呼叫與未執行不同。totalDurationMs 包含 bridge 與 Session 子流程，原 Session 分段另見 diagnostics.session；各 stage 可重疊，不相加。

完整流程耗時由 agent 記開始、稿件核對完成、使用者等待與 ERP 邊界；不把 collector 時間當端到端耗時，3 分 13 秒不是 assertion／timeout／SLA。清理需等草稿及最終稿交付；過程不回顯私人全文、原始錯誤或內部路徑。

三種來源交同一份完整證據給 erp-daily-work-log。來源不改工時／請假、官方 context／options、分類、append／replace／output_only、完整 Markdown／JSON／intent、fresh snapshot、授權及完整讀回。來源或手動內容改變送出意圖時重新預覽並取得相應授權；單純重 preview 重用有效準備，真正 write 前才 fresh 核對。無自動或手動內容時不造日誌／工時。
