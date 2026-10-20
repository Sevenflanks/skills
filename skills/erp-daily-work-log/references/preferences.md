# 個人偏好記憶

將已確認的分類與參照當作下次預覽的提示。偏好不構成本次 options 合法性、日誌提交、覆蓋日誌或 ERP 共用 repo mapping 的授權。

## 操作順序與同意範圍

1. 沿用外部 `erp` access 在本次 runtime 解析的同一 config 位置。讀取 `show`／`PreferenceStore.read()`；沒有檔案或沒有 `dailyWorkLog` 時視為停用，讀取不建檔、不建立 credential 設定。
2. 使用者**明確同意啟用偏好記憶**後，才執行 `enable --consent`／`set_enabled(True, consent=True)`。flag 是 caller 已取得同意的紀錄；helper 不會替使用者取得同意。必須已有合法 access config；缺檔時先由外部 access 的設定流程處理，不能為偏好另建 shadow config。
3. 從 collector 的 canonical `githubRepo`、工作所屬日期的可靠 branch 證據與已釐清的 topic 建立精確 scope。三者皆相等才可套用；缺少或多義時先詢問。helper 不讀 Git、不推測 branch，也不以目前 checkout 充當補報日期的 branch 證據。
4. 在本次 `reportDate` 的官方 options 核對分類、project、所選 project 的 module 清單或 RD 立案書。已記憶 ID 失效、缺必填參照或有歧義時，修正／詢問後再預覽；不可把偏好當作合法 options 清單。
5. 使用者在預覽中確認新選擇時，當次採用新選擇。已啟用記憶則以 `remember(..., confirmed=True)` 取代**同一精確 scope** 的舊選擇，不再問一次是否永久覆寫；其他 scope 不變。`confirmed` 指選擇已被確認，不是日誌提交授權。
6. 明說「僅本次」時用 `only_this_time=True`／`--only-this-time`：當次預覽仍使用新選擇，helper 保持原 config bytes 不變，回傳的也是原偏好區塊。停用時 `remember` 同樣不保存、不自動重新啟用。
7. 保存後以新的 `PreferenceStore` 或 `show` 讀回偏好；進入提交流程前仍需本次 options 與完整提交意圖核對。此讀回只確認本機偏好，不代表 ERP 日誌已填寫。

`disable`／`set_enabled(False)` 保留既有 choices 但關閉自動套用與保存。重新啟用仍須明確同意。啟用／停用只影響本機個人偏好，共用 mapping 維護與日誌提交各自取得授權。

## 唯一 namespace 與精確 scope

只讀寫 access config 的 `dailyWorkLog` 區塊；沒有舊偏好區塊的 migration、別名或通用 namespace 介面：

```json
{
  "enabled": true,
  "choices": [
    {
      "scope": {
        "githubRepo": "Sevenflanks/skills",
        "branch": "feat/39-erp-worklog",
        "topic": "偏好記憶"
      },
      "choice": {
        "reportType": "PROJECT",
        "projectId": 101,
        "projectModuleId": 202,
        "mandateCharterId": null
      }
    }
  ]
}
```

- `githubRepo`：collector 提供的 canonical `owner/repo`；保留其大小寫，精確比較。不接受 URL、`.git` 後綴、資料夾名稱或 wildcard；helper 不自行 canonicalize。
- `branch`：caller 由可靠證據取得的確切 branch 名稱，前後空白、wildcard、`HEAD`、`unknown`、不合法 ref 形式等拒絕。語法驗證不能證明歷史 branch；來源可靠性由 caller 確認。不同 branch 不自動合併。
- `topic`：使用者已釐清且穩定的短主題識別（1–120 字元、無前後空白／控制字元／wildcard），不是工作日誌內容。不同主題不自動合併。`reportDate` 不作永久 key，但每次套用前仍依所報日期建立 scope 證據。
- `choice` 必須恰有上述四欄，不保存 auth、subject、description、todos 或其他日誌文字。`reportType` 只接受 COMPANY／PROJECT／RD／OTHER／LEAVE；ID 為正整數且不超過 signed Long 上限，非適用欄位填 `null`。
- PROJECT 必須有 `projectId`，可記 `projectModuleId`；RD 必須有 `mandateCharterId`。其他分類的三個參照必須皆為 `null`。這些只是基本形狀檢查；module 的實際必填與合法關聯、RD 可用性及 LEAVE 的實際請假資料仍依本次官方契約核對。

## Python API（Python 3.8+，standard library only）

從 `scripts/preferences.py` 載入 `PreferenceStore` 與 `PreferenceError`：

```python
store = PreferenceStore(config_root=resolved_config_root)
# 或 PreferenceStore(config=resolved_config_file)，兩個位置參數互斥。
block = store.read()                         # 只回傳偏好區塊的獨立副本
hint = store.choice(scope)                   # enabled 且 scope 完全相同才回傳 choice，否則 None
store.set_enabled(True, consent=True)        # 已明確同意啟用
store.remember(scope, choice, confirmed=True)
store.remember(scope, new_choice, confirmed=True, only_this_time=True)
store.set_enabled(False)                     # 保留 choices，停止套用／自動保存
```

`PreferenceStore(config=None, config_root=None)`、`read()`、`choice(scope)`、`set_enabled(enabled, consent=False)`、`remember(scope, choice, confirmed=False, only_this_time=False)` 是公開介面。寫入方法回傳保存後的偏好區塊；`remember` 停用／僅本次時回傳原區塊而不寫入。`read()` 是此 instance 載入的 snapshot；需要重新讀檔時建立新 instance。

`config_root` 指共用 root，helper 在其下取 `erp/config.json`；`config` 指完整檔案位置。未傳入時使用既有 shared-root 慣例 `~/.config/softleader/agent-skills`。有 runtime／外部 access 覆寫時，每次必須顯式傳入相同位置；helper 不額外讀取另一份 access 設定來猜 root。

## CLI

位置 flags 放在 subcommand 前；下列 `$configRoot` 必須是外部 ERP access **本次已解析**的共用 root：

```powershell
python -B skills/erp-daily-work-log/scripts/preferences.py --config-root "$configRoot" show
python -B skills/erp-daily-work-log/scripts/preferences.py --config-root "$configRoot" enable --consent
python -B skills/erp-daily-work-log/scripts/preferences.py --config-root "$configRoot" disable
```

明確檔案位置改用 `--config "$configFile"`。`remember` 接受 `--scope <JSON>`、`--choice <JSON>`、`--confirmed`，及選用的 `--only-this-time`。Windows PowerShell 5.1 的 native argument JSON 引號容易被 shell 吃掉；呼叫端可用以下 Python argument-list 方式，避免手工 shell escaping：

```python
import json
import subprocess
import sys

subprocess.run([
    sys.executable, '-B', 'skills/erp-daily-work-log/scripts/preferences.py',
    '--config-root', str(resolved_config_root), 'remember',
    '--scope', json.dumps(scope), '--choice', json.dumps(choice), '--confirmed',
], check=True)
# 僅本次：在 argument list 末尾加 '--only-this-time'。
```

成功 exit 0，stdout 僅為偏好區塊 JSON（不是原 config，也不附完整路徑）。失敗 exit 2，stdout 空白，stderr 僅為固定 `{"error":"錯誤碼"}`，不回顯輸入或 traceback。`--help` 可查參數。

## 安全寫回與失敗處理

- 整份 config 必須是合法 JSON object；任何層級 duplicate key、NaN／Infinity 或無效 `dailyWorkLog`（含未知欄位、重複 scope）皆 fail closed，保留原檔。沒有 namespace 的既有 config 可用；未知的其他 top-level／巢狀 keys、credential 型別及數值完整保留。
- 浮點 JSON token 以 `Decimal` 解析／輸出，不經 binary float；大型整數保持整數。超出 Python 整數解析限制或 `Decimal` 可表示範圍的極端 token 會拒絕並保留原檔，不截斷／四捨五入。JSON 空白、數字 exponent 的拼字與排版不保證相同，精確數值不變。停用／僅本次的 `remember` 完全不改原始 bytes。
- 原 config 與所有祖先若是 symlink 或 Windows reparse point，直接拒絕；hardlink、非 regular file 也拒絕。helper 不追蹤連結、不改寫連結 target、不建立 config 目錄。
- Windows：先確認 volume 支援 persistent ACL；以 protected owner-only DACL 原生建立同目錄暫存檔，再用 `ReplaceFileW(flags=0)` 保留原目標 security。無法安全建立或保留 ACL 時拒絕，不使用 ignore-ACL-errors 或降低權限檢查。
- POSIX：僅接受目前使用者擁有、owner 可寫且 mode 不超過 `0600` 的 config，直接 parent 也須屬於目前使用者且無 group／other write；有 extended attributes 時保守拒絕。暫存檔 private `0600`，保留原檔 mode，以同目錄 replace 原子替換。這是保守支援範圍，不是跨平台 ACL 管理框架。
- 每個 instance 記住載入時的 bytes 與檔案 metadata；寫入前、暫存檔 flush／fsync 後各 fresh-read compare，若改變則回 `config_changed_reload_required`，caller 應重新載入並重新評估選擇。這避免覆蓋 caller 的舊內容；**compare 與 replace 之間仍有競爭窗口，不是完全 atomic CAS，也不是 hostile filesystem 的防競態沙箱**。
- 一般失敗會刪除自身暫存檔；`private_temp_cleanup_failed` 表示清理未完成，需在本機私下處理。程序被外部強制終止也可能留下 private 暫存檔；不要將其內容加入 repo 或輸出。helper 不啟動常駐 process。

常見錯誤：`enable_consent_required`（尚未明確同意）、`confirmed_choice_required`（選擇未確認）、`existing_access_config_required`（尚無 access config）、`invalid_preferences_namespace`（區塊無效）、`linked_config_path`（連結路徑）、`private_temp_unavailable`／`safe_replace_failed`／`unsupported_config_permissions`（安全寫回條件不足）。先處理實際原因，再以新 instance 讀回；不自動重試、不自行修復或重建 credential 設定。
