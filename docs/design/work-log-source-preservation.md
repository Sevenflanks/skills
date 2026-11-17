# 工作日誌來源整合能力對照（#66／#67）

本對照先於實作建立。原 Session reader 留在原 collector，新增來源路由不改寫 adapters。

| 現有能力 | 新流程保留位置 | 驗收 |
| --- | --- | --- |
| probe、預告、固定日期、capture 純 JSON／私有 UTF-8 | 共用 capture；按 evidenceSource 探測，與 repo SourceMode 分開 | source_modes 公開 capture；原 capture/windows harness |
| OpenCode＋Codex 合併、有界日期讀取、DB fallback、權威空結果 | 明確 Session；combined 的 Session 分支 | 原 multi-source、Codex、bounded、discovery suites；Session 正向案例 |
| continuation／mirror 去重、coverage、compatibility draft 交付與清理 | 原 Session adapters 與 formatter 保留 | 原 multi-source、index、selection、windows harness |
| repo／worktree、scan roots、remote、當日 branch | Session 原路徑；GitHub 使用 canonical repo 與 PR head，唯讀本機 remote 補辨識 | 原 repo-discovery；source_modes remote-only／worktree／缺 remote |
| Git／GitHub 補證與精準 Issue 狀態／同輪重用 | Session 原路徑；新 provider 共用 request cache 與精確 repo/type/number | 原 efficiency；source_modes attribution／date／pagination |
| bounded index、repo/session/raw pointer、完整 ERP view、歷史 evidence | 原 formatter 加入 issues／manual／attribution，原位置不重編 | source_modes CLI→ERP/raw；原 selection/evidence-view |
| 分段診斷、錯誤與 partial、不外洩 raw error | Session 原 diagnostics；新 provider 記錄呼叫／快取／上限與安全錯誤碼 | 原 diagnostics；source_modes partial／failure |
| ERP context／options、工時／假勤、歸屬、append／replace／output_only | 原 ERP helper；來源只改證據輸入，不改提交協定 | 原 ERP helper suites；三來源 consuming-agent |
| 同 plan 完整 Markdown、intent／snapshot、授權、readback、retry／mapping guards | 原 ERP preview／transport／readback；來源或手動內容改變意圖重 preview | 原 append／Markdown／readback／preferences／mapping suites |

刻意改變：To 統一半開，Session caller 以 To−1 tick 呼叫原 inclusive adapters，預設 To 為次日午夜；公開日界線案例觀察 next-day／sql-next-day 被排除。未指定時採 GitHub，不讀本機 session；舊 SourceMode=session/scan/mixed 仍只選 repo 探索方式。舊 Session 回歸明確傳 EvidenceSource=session。GitHub 模式不把 Git history 作成果入口。GitHub 空／失敗不自動轉 Session。

主題合併屬 consuming agent 的語意決策；collector 保留全部原始項目與 canonical 關聯，不用標題相似或共用 parent 強制合併。測試須分別記錄 helper 行為與 agent 實際產生的日誌／ERP plan，不將文件 harness 當作模型通過。
