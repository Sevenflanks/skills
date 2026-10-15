# Helper 操作與恢復

## Runtime 與私有工作區

需 Python 3.11+ 與 standard library sqlite3，無 pip 依賴。Windows 支援所有指令；其他平台僅 quick、plan、inspect-run。host gate 使用 Windows PowerShell CIM，隔離程序視野時須 host escalation；觀察失敗不是離線證據。缺 runtime 就回報，不假設 Bun 或 SQLite CLI 可替代。

先解析 `$skillRoot` 為實際安裝目錄、`$taskWorkDir` 為本次私有工作區。run-root 不放公開 repo、來源 DB 目錄或 cache。以下為 PowerShell，其他 shell 使用相容 quoting。

```powershell
$pruneHelper = Join-Path $skillRoot 'scripts/maintenance.py'
$pruneRunRoot = Join-Path $taskWorkDir 'opencode-db-prune'
python $pruneHelper quick --source $sourceDb
```

quick 只讀 SQLite pager/schema metadata 與 main/WAL/SHM/journal 大小，不掃歷史。預設 freelist 至少 1 GiB 且占 10% 建議 estimate_compact，可用 `--min-reclaim-gib`、`--min-free-ratio` 調整。skip_or_request_full_estimate 不代表激進模式無效益；明確要求完整估算時繼續 plan。freelist 不等於保證回收，新 DB 大小必須另估算。quick 是可變動的觀察，不能當 offline gate。

## 完整估算與固定政策

```powershell
python $pruneHelper plan --source $sourceDb --run-root $pruneRunRoot
python $pruneHelper plan --source $sourceDb --run-root $pruneRunRoot --mode aggressive --days 30 --original delete
```

第一行預設 compact + keep：所有表、原始內容、event 原樣保留，切換後仍保留原檔。第二行明確選用激進模式、30 天、切換驗證後刪原檔；plan 本身都不授權執行。

來源預設取 XDG_DATA_HOME 或 `.local/share/opencode/opencode.db`。Deja 選用且不影響模式：從 PATH 偵測 exe/cmd/ps1 shim，不執行或安裝；非 PATH 位置可給 `--deja-executable`。保護來源旁 `storage/session_diff`；XDG_CACHE_HOME 的 `deja/index.db` 已存在或偵測到 Deja 時加入 preserve paths。其他位置以 `--preserve-path` 加入。cache 不代表 reader 可用或版本相容；無 Deja 仍能使用兩種模式。

每次建立獨立 run directory，含 policy.json、estimate.json。plan 使用 mode=ro/query_only transaction 取得包含 WAL 的一致 snapshot；不 checkpoint、不改 DB、不建 candidate。一般 WAL reader 的 shared-memory 狀態仍由 SQLite 管理。長 read transaction 可能延遲 WAL 回收，預設 deadline 1,800 秒；大量歷史建議離線估算。

估算與 build 共用 retained_rows 保留管線。compact 讀所有 event；aggressive 只讀近期 event。逐列 payload/row/index 餘裕形成估算範圍，dbstat 不可用時採保守 fallback。這不是新檔大小上限；單一巨大 row 或 OS 寫入仍可能超出預估。起始空間包括 candidate 上緣、索引暫存及預設 8 GiB 餘裕；SQLite temp 磁碟另行檢查，建置期間批次／索引／progress callback 持續檢查，並非硬 quota。

policy format_version=3 固定模式、原檔處置及 aggressive cutoff（30 天即 720 小時）。等待不後移門檻；最後離線重新取近期 IDs。compact 無日期門檻。舊 format 1/2、deja-v1 或需求改變須重新 plan，不默轉政策。估算的 estimated_reclaim_bytes 是刪原檔後的潛在效益；keep 切換後同時占用新舊 DB，estimated_net_freed_after_promotion_bytes 會為負值。

## 相容性診斷

compatibility.json 列出已審查 schema ID、完整結構與 SHA256；未記錄 OpenCode 版本時明示未知，不猜 release。未知 schema 拒絕 plan/build，輸出 observed SHA、supported ID、user_version/application_id，及每個已支援結構的 added/missing/changed objects。僅列物件識別名稱，不輸出 SQL literal 或資料列。

新增支援時先對照來源 migration、對話讀取路徑、FK/event 契約，補真實 SQLite fixture 與回歸測試，再加入 reviewed manifest；不能只換 SHA。aggressive 另要求替代對話 store 為空。要求保證特定工具查找能力時，另核對該 reader 版本；Deja 不是通用清理必要依賴。

## 離線與執行

```powershell
python $pruneHelper status --source $sourceDb
```

exit 0 僅表示 eligible_for_offline_lock_check；exit 2 表示仍有 OpenCode，exit 1 表示觀察失敗。host probe 要求可見 System PID4 與自身 PowerShell，仍須由真實主機工具層執行。全部 UI/CLI/server 均須退出；不 kill、不 close。只有使用者要求等待／監控才建 heartbeat，只停止本次重複觸發，不改其他 automation。Deja/MCP 的鎖阻礙操作時保留資料並回報，不強制終止。

從 plan 輸出解析 `$prunePolicy`，report 放同次私有 run directory 的新檔案：

```powershell
$pruneReport = Join-Path (Split-Path -Parent $prunePolicy) 'rebuild-report.json'
python $pruneHelper build --policy $prunePolicy --report $pruneReport --execute
python $pruneHelper promote --policy $prunePolicy --report $pruneReport --execute
```

上例適用 keep。只有收到本次明確執行指令才傳 --execute。delete policy 的 build/promote 另須 --accept-no-full-backup，且人類已接受不另做完整備份與驗證後刪原檔；旗標不能代替人類決定，不永久儲存 backup waiver。要求完整備份時另行完成，keep 原檔不是異碟備份。

build 的唯一來源寫入是 SQLite-managed checkpoint；關閉連線並確認 sidecars 不存在，再持有 GENERIC_READ + FILE_SHARE_READ|FILE_SHARE_DELETE guard。它拒絕 writer，access=0 無此效果。再次核對 sidecars/身分，才 immutable 讀取。來源不做 DELETE/VACUUM。

candidate 必須為同目錄新檔，rollback/report 不得已存在。保留 schema、migration、原始 rowid、SQLite metadata、legacy sqlite_sequence。先資料後索引；各表 rowid/型別/值 digest、完整 integrity_check/FK、schema/metadata 及來源/candidate 全檔 SHA256 通過才記錄 candidate_validated。

promote 重核 policy、路徑、來源/candidate ID/size/mtime/SHA、離線與無 sidecars。以 ReplaceFileW 切入新檔並將原檔改名 rollback，無需再複製整份原檔。replacement API 要求切換前釋放 candidate guard；切換後立刻 guard 新檔，失敗保留檔案。新檔 quick_check/FK/SHA、外部 preserve paths digest、程序狀態通過後記錄 post_switch_validated：

- keep：記錄 original_retained，切換完成、原檔保留；reclaimed_main_bytes=0，net_freed_bytes 為負的新 DB 大小。
- delete：以 DELETE handle 與全程持有的原檔 handle 比對 file ID，SetFileInformationByHandle 刪原檔，記錄 complete；此處不可逆。檔名被其他檔占用時不刪它，回報確認。

## 日後刪除已保留的原檔

收到新的明確刪除授權與 backup waiver 後：

```powershell
python $pruneHelper purge --policy $prunePolicy --report $pruneReport --execute --accept-no-full-backup
```

僅接受原 keep policy 的 original_retained report，且 digest/路徑吻合。重新確認離線、無來源/rollback sidecars、Windows guard、目前 DB 仍是切換的新檔（同 file ID）、schema/integrity/FK、原檔完整 ID/size/mtime/SHA。允許目前 DB 正常增加資料，不要求舊 candidate SHA 仍相同；目前 DB 被替換或 migration 改 schema 就拒絕。最後仍用 handle-bound delete。若已重開 OpenCode 且 WAL 尚在，先正常退出相關程式；不手動刪 sidecars。purge 不自動回復 DB，也不清空 Deja cache。

## 唯讀診斷與恢復

```powershell
python $pruneHelper inspect-run --policy $prunePolicy --report $pruneReport
python $pruneHelper inspect-run --policy $prunePolicy --report $pruneReport --verify-hashes
```

檢查 source/candidate/rollback 的存在、file ID、sidecars、對應記錄的角色及最後階段。可選全檔 SHA 較昂貴；有 sidecars 時不驗 hash，變動的觀察不能當 offline gate。report 不匹配 policy 時不信任角色。此指令不開 SQLite、不套 WAL、不 checkpoint、不重試、不刪檔；即使 source 已被移走也可使用。

| 階段／實際狀態 | 下一步 |
| --- | --- |
| plan 失敗／未知 schema | 保持來源原樣；審查 migration 與結構差異 |
| building／驗證失敗 | 不 promote，保留來源與部分 candidate，確認歸屬後另設計處理 |
| candidate_validated 且檔案角色正常 | 仍需原 policy、授權、fresh host/identity/SHA gates 才 promote |
| promotion_started／source 不見／有 sidecars／檔名異常 | 全部保留，人工確認每個 DB 與 sidecars 配對，禁止盲目 retry |
| original_restored_candidate_retained | 安全情況已復回原檔；修正失敗原因後重新 plan |
| original_retained | 保留原檔，或另行授權 verified purge |
| post_switch_validated／complete | 核對實際檔案；report 寫失敗也可能已刪原檔，不聲稱一定保留 |

ReplaceFileW error1177 可能已移走 original；[Windows 文件](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew) 記載部分完成狀態。只有已拿到新 guard、新舊身分可證且無 sidecars 的 post-check 失敗才自動換回原檔。其他情況全部保留，不手動刪 WAL/SHM、不把新 WAL 配到原 DB、不殺 reader 解鎖。清除未完成 candidate 需先證實來源安全與歸屬，並有刪除授權；rollback 不當一般暫存檔。

## 驗證邊界

CI 於 Windows/Linux、Python3.11/3.12 跑 unittest；Linux 明確 skip Windows sharing/ReplaceFileW/purge 案例，仍執行 readonly SQLite plan、quick、schema、inspect-run。實際檢查結果以該次 CI 為準。測試不讀正式 DB，不證明硬體故障、斷電、所有 OS race 或真實 Deja 搜尋結果；每次實際清理仍需完整驗證。
