# #43／#44 合成驗證證據

本目錄只保留合成 fixture 與其代表輸出，不含個人 session、私有 worktree path、憑證或真實 API 回應。

## 改前／改後

同一 fixture：兩個 worktree，共用 `fixture/shared`；OpenCode metadata 與兩份 Codex 同 session 續行；A／B 各有一筆不同 hash／branch 的當日 commit。Git／gh／OpenCode CLI 是子 process 邊界替身；Codex JSONL 由真實 collector reader 讀取。

| 單次 collection 外部查詢 | base `9ff9580` | 修正後 |
| --- | ---: | ---: |
| viewer (`gh api user`) | 3 | 1 |
| PR list | 2 | 1 |
| PR detail | 6 | 3 |

三個 PR 候選共用同作者與當日時間，#1 只靠 branch 連到 A（無相同 hash），#2 只靠 hash 連到 B（無相同 branch）。基線還會將同作者無 local hash／branch 關聯的 #3 納入；修正後 A 只收 #1，B 只收 Draft #2。每次新 collection 仍重新查詢。失敗案例另驗證 shared list failure／invalid detail JSON 不重試，且兩個 worktree 都有缺口；invalid viewer 不視為認證成功、不補查 PR。

ERP 視圖的獨立既有 schema fixture 包含兩個 repo、10 commits（超過 summary 預設8）、MERGED／OPEN+Draft／CLOSED-unmerged／未知 head及Draft、closing issue、7 sessions（第7筆是 Codex 續行）、sources／partial coverage／global與repo gaps。`formatter-input.json` 與 `erp-view.json` 是實測產物；`output-bytes.json` 計 UTF-8 內容 bytes，不計檔案 BOM／寫檔尾 newline。實測 8,817 → 5,027 bytes；縮減來自 JSON 無縮排與移除 repo path，沒有刪除 commit／session 證據。這不是 token、latency、memory 或真實 workload 的量測。

## 可重現命令

```powershell
pwsh -NoProfile -File skills/daily-work-log/tests/evidence-view.tests.ps1 -Case reuse -BaselineRevision 9ff9580 -MeasureOnly -EvidenceRoot '<external-before>'
pwsh -NoProfile -File skills/daily-work-log/tests/evidence-view.tests.ps1 -Case all -EvidenceRoot '<external-after>'
pwsh -NoProfile -File skills/daily-work-log/tests/evidence-view.tests.ps1 -Case formatter -EvidenceRoot skills/daily-work-log/tests/evidence
```

前兩條命令的 collection 代表檔將本次 temp root 替換成 `<synthetic-task>`。所有 fixture process 都同步等待完成，finally 刪除當次合成目錄並還原 PATH；`EvidenceRoot` 只保留明確要求的合成產物。

## Red → green 與 mutation 對應

| 被保護的行為／可致錯 mutation | 測試 seam 與證據 |
| --- | --- |
| 空 commit 提早 return／把 canonical 清成 null | `-Case canonical` 初次 red：有效 remote 得不到 canonical；修正後 green。 |
| 接受相似 host／三段 identity，或 missing remote 用資料夾猜 | `canonical` 的 malformed／non-GitHub／missing cases，要求 null 及 remote gap。 |
| session-only 虛構 commit／PR，或 current checkout 補歷史 branch | `canonical` 檢查公開輸出及 git／gh 呼叫，無 commit／PR及無 checkout查詢。 |
| 刪掉 collection cache／多次 viewer／跨 collection 永久cache | `reuse` 初次 red：3／2／6；修正後 green：1／1／3，新 collection 再查一次。 |
| 把已過濾 PR 共用給另一 worktree／恢復 author-only fallback | `reuse` 要求 A=#1、B=Draft #2，#3 不在任一結果；既有 Pester 同步收緊 #3 的期待。 |
| 刪掉 branch-only 或 hash-only 關聯／傳錯 canonical repo | `reuse` 的 #1／#2 分別只能透過一種關聯命中；CLI 替身拒絕錯誤 `--repo`，要求仍有對應 PR 輸出。 |
| 失敗重試／吞掉共用失敗缺口／bad viewer當認證成功 | `failures` 檢查兩個 worktree warning、零虛構 PR 與精確查詢次數。 |
| 移除 InputPath／ERP view | `formatter` 初次 red：不存在 InputPath 參數；修正後從檔案輸入成功。 |
| ERP套8筆上限／刪refs、head、Draft、issues／把null猜成false | `formatter` 要求10 commits、literal refs與PR狀態、closing #101、null保留。 |
| 只保留前五sessions／丟第二來源、續行或coverage／gaps | `formatter` 要求7 sessions、child／resume檔、完整meta相等與所有warnings/errors。 |
| ERP新功能破壞預設summary格式 | `formatter` 仍有8 shownCommits、文字PR；既有Pester compaction通過。 |

工具測試已實際執行；agent 流程 evals #34–#36 已加入，但未在此回合呼叫獨立 consuming agent，因此 HTTP400 停止／branch 多義詢問的模型行為尚無實跑評分。這些規則屬 skill，collector 不包含 ERP resolver。
