# skills

這是個人維護的 Agent Skills 倉庫，用來集中管理可重用的 OpenCode／Claude-style skills。

此倉庫會隨時間加入更多 skills。每個 skill 都放在 [`skills/`](skills/) 底下獨立的資料夾中，並以 `SKILL.md` 作為主要定義檔；若有測試或評估案例，則放在該 skill 自己的 `evals/` 目錄中。

## 目前收錄的 skills

| Skill | 版本 | 狀態 | 說明 | 路徑 |
| --- | --- | --- | --- | --- |
| `code-intent-comments` | `0.1.0` | stable | 引導 agent 以白話繁中撰寫高價值程式註解，補足 class 責任、核心邏輯、CR、相容性與高風險脈絡。 | [`skills/code-intent-comments/`](skills/code-intent-comments/) |
| `daily-work-log` | `0.1.4` | stable | 從 OpenCode session、跨 branch git commit 與 GitHub PR / issue 關聯蒐集證據，整理成每日工作日誌。 | [`skills/daily-work-log/`](skills/daily-work-log/) |
| `gh-body-file` | `0.1.1` | stable | 在 Windows、PowerShell、OpenCode shell 環境中，安全使用 GitHub CLI 支援 `--body-file` 的指令。 | [`skills/gh-body-file/`](skills/gh-body-file/) |
| `agent-process-lifecycle` | `1.0.0` | stable | 管理 Agent 啟動之本機 OS process 的 ownership、execution tier、readiness、Stop、Preserve、handoff 與 reconciliation；Windows 提供 self-managed helper，non-Windows 僅分類、handoff 或 launch 前 blocked。 | [`skills/agent-process-lifecycle/`](skills/agent-process-lifecycle/) |

完整 catalog 可見 [`skills.json`](skills.json)。若需要 Claude plugin-style metadata，可見 [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json)。新增、調整或移除 skill 時，請同步更新 catalog 並執行驗證。

## code-intent-comments

`code-intent-comments` 會引導 agent 在寫程式時補上人類工程師需要的意圖型註解。它要求註解說明原因、限制、風險、使用者需求、舊資料相容與不可簡化原因，而不是把程式碼翻成中文。

適用於需要補足維護脈絡的程式變更，例如：

- class/module 責任與邊界。
- 核心 method、特殊流程、金額/rounding/冪等/狀態轉換。
- User 要求、CR、舊資料相容、legacy 或 framework workaround。
- 本次 touched code 附近不足、過時或模糊的既有註解。

簡單 typo、格式調整、明顯 config rename 不需要套用，除非有外部相容風險。

## daily-work-log

`daily-work-log` 會先用固定 PowerShell helper 從本機 OpenCode 活動、`git log --all` 結果與 GitHub PR / issue 關聯蒐集證據，並要求 helper 只輸出純 JSON。之後 skill 再根據 JSON 內容，將工作內容壓成優先依 GitHub repo name 分組、必要時 fallback 到資料夾名稱的每日工作日誌。

適用於需要整理今日或指定時間範圍的工作摘要，例如：

- 從 OpenCode session 反推今天實際工作的 repo。
- 收集不限 branch 的 git commits。
- 使用 `gh` 補充 PR 編號與 closing issue 關聯。
- 輸出適合直接貼到 standup / 日報的簡短條列。

若 `gh` 不可用或未登入，此 skill 會要求 agent 預設先停止並建議安裝 GitHub CLI 或執行 `gh auth login`；只有使用者強烈堅持時才降級繼續並保留 PR / issue 補證缺口。repo 非 git、或 session 有進入但沒有 commit 時，也會要求 agent 保留資料缺口說明，而不是直接忽略。

## gh-body-file

`gh-body-file` 會引導 agent 將 Markdown 內容先寫入暫存 `.md` 檔，再透過 `gh ... --body-file` 傳給 GitHub CLI，最後在 `finally` 區塊中清理暫存檔。這可避免 Windows／PowerShell／OpenCode shell 在多行 Markdown、引號或特殊字元上的命令列 quoting 問題。

適用於支援 `--body-file` 的 GitHub CLI 指令，例如：

- `gh issue create`
- `gh issue comment`
- `gh issue edit`
- `gh pr create`
- `gh pr comment`
- `gh pr edit`
- `gh pr review`
- `gh pr merge`
- `gh pr revert`

使用前仍應先確認目標 `gh` 子指令確實支援 `--body-file`；若不支援，就不要套用此 workaround。

## agent-process-lifecycle

`agent-process-lifecycle` 管理 Agent 啟動且可能跨越 initiating tool call 的本機 OS process 之 ownership、execution tier、readiness、Stop、Preserve、handoff 與 reconciliation。它不是 generic process manager，也不負責 Browser QA、downstream workload 或整體 task 成功判定。

同步等到正常 exit 的 command 不適用。若 framework、IDE、Kubernetes、Docker、Windows Service、CI 或其他 external／runtime owner 已明確且具有完整 lifecycle contract，skill 不接管既有資源；需要釐清 owner 時才以分類與 handoff 回應。

Windows 依序選擇第一個 viable tier：verified managed lifecycle、verified external launcher、Windows self-managed helper，最後才是 blocked 或 handoff。各 tier 不競速；較低 tier 前必須先完成 Stop、Preserve、handoff 或 unresolved reconciliation。caller 提供 workload-specific readiness signal 與 deadline，不能以 spawn、liveness、fixed sleep 或 port occupied 取代 readiness。

Launch 前先選擇 `Stop` 或 `Preserve`。`Stop` 必須有 live identity-bound ownership proof；`Preserve` 必須指定 later owner 並交付 fresh binding、record、stdio、readiness 與日後的 Stop 方法。`Preserve` 是 responsibility handoff，不是 cleanup 完成。

`1.0.0` 僅在 Windows 執行 lifecycle。non-Windows 僅做 bounded 分類：可辨識 owner 時 handoff，否則在 launch 前 blocked；不做 OS inspection、lifecycle shell call、launch 或 termination。

## 倉庫結構

```text
skills/
├── code-intent-comments/
│   ├── README.md
│   ├── SKILL.md
│   └── evals/
│       └── evals.json
├── daily-work-log/
│   ├── README.md
│   ├── SKILL.md
│   ├── evals/
│   │   └── evals.json
│   └── scripts/
│       └── collect-daily-work-log.ps1
├── gh-body-file/
│   ├── README.md
│   ├── SKILL.md
│   └── evals/
│       └── evals.json
└── agent-process-lifecycle/
    ├── README.md
    ├── SKILL.md
    ├── evals/
    │   └── evals.json
    ├── references/
    │   ├── failure-and-handoff.md
    │   └── windows-self-managed.md
    └── scripts/
        ├── Invoke-AgentProcessLifecycle.ps1
        └── JobHandleHolder.ps1
```

- `code-intent-comments` 說明文件：[`skills/code-intent-comments/README.md`](skills/code-intent-comments/README.md)
- `code-intent-comments` 定義檔：[`skills/code-intent-comments/SKILL.md`](skills/code-intent-comments/SKILL.md)
- `code-intent-comments` 評估案例：[`skills/code-intent-comments/evals/evals.json`](skills/code-intent-comments/evals/evals.json)
- `daily-work-log` 說明文件：[`skills/daily-work-log/README.md`](skills/daily-work-log/README.md)
- `daily-work-log` 定義檔：[`skills/daily-work-log/SKILL.md`](skills/daily-work-log/SKILL.md)
- `daily-work-log` PowerShell helper：[`skills/daily-work-log/scripts/collect-daily-work-log.ps1`](skills/daily-work-log/scripts/collect-daily-work-log.ps1)
- `daily-work-log` 評估案例：[`skills/daily-work-log/evals/evals.json`](skills/daily-work-log/evals/evals.json)
- `gh-body-file` 說明文件：[`skills/gh-body-file/README.md`](skills/gh-body-file/README.md)
- `gh-body-file` 定義檔：[`skills/gh-body-file/SKILL.md`](skills/gh-body-file/SKILL.md)
- `gh-body-file` 評估案例：[`skills/gh-body-file/evals/evals.json`](skills/gh-body-file/evals/evals.json)
- `agent-process-lifecycle` 說明文件：[`skills/agent-process-lifecycle/README.md`](skills/agent-process-lifecycle/README.md)
- `agent-process-lifecycle` 定義檔：[`skills/agent-process-lifecycle/SKILL.md`](skills/agent-process-lifecycle/SKILL.md)
- `agent-process-lifecycle` 評估案例：[`skills/agent-process-lifecycle/evals/evals.json`](skills/agent-process-lifecycle/evals/evals.json)
- `agent-process-lifecycle` failure 與 handoff reference：[`skills/agent-process-lifecycle/references/failure-and-handoff.md`](skills/agent-process-lifecycle/references/failure-and-handoff.md)
- `agent-process-lifecycle` Windows self-managed reference：[`skills/agent-process-lifecycle/references/windows-self-managed.md`](skills/agent-process-lifecycle/references/windows-self-managed.md)
- `agent-process-lifecycle` Windows helper：[`skills/agent-process-lifecycle/scripts/Invoke-AgentProcessLifecycle.ps1`](skills/agent-process-lifecycle/scripts/Invoke-AgentProcessLifecycle.ps1)
- `agent-process-lifecycle` Job handle holder：[`skills/agent-process-lifecycle/scripts/JobHandleHolder.ps1`](skills/agent-process-lifecycle/scripts/JobHandleHolder.ps1)

## 安裝方式

依照你的 agent runtime 支援的方式安裝 GitHub-hosted skill；或直接將需要的 skill 資料夾複製到本機 skills 目錄。

以 OpenCode-style 的本機安裝為例，可複製需要的 skill 資料夾到你的 skills 目錄。一般 published skill 至少包含：

```text
<skill-name>/
├── README.md
├── SKILL.md
└── evals/
    └── evals.json
```

## 新增 skill 的慣例

未來新增 skill 時，請使用以下結構：

```text
skills/
└── <skill-name>/
    ├── README.md
    ├── SKILL.md
    └── evals/
        └── evals.json   # skill 有可驗證行為時建議加入
```

並同步更新本 README 的「目前收錄的 skills」表格、[`skills.json`](skills.json)，以及 [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json)。若 skill 沒有可驗證行為，`evals/evals.json` 可省略；若有固定流程、轉換、驗證條件，建議提供 evals。

你也可以從 [`templates/SKILL.template.md`](templates/SKILL.template.md) 與 [`templates/evals.template.json`](templates/evals.template.json) 開始建立新 skill。

## 驗證

本倉庫提供無外部套件依賴的驗證腳本：

```powershell
npm run validate
```

或直接執行：

```powershell
node scripts/validate-skills.mjs
```

驗證會檢查：

- `skills.json` 格式與路徑是否正確
- 每個 catalog entry 是否有對應的 `SKILL.md`
- `SKILL.md` 是否包含必要 frontmatter：`name`、`description`
- `SKILL.md` 是否包含 `license`、`metadata.author`、`metadata.version`
- `skills.json` 與 `.claude-plugin/marketplace.json` 的版本是否與 `SKILL.md` 一致
- `evals/evals.json` 若存在，是否為合法 JSON 且 `skill_name` 與 skill 名稱一致
- catalog 是否有重複 skill 名稱或路徑

更多結構說明請見 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)，驗證規則請見 [`docs/VALIDATION.md`](docs/VALIDATION.md)。

## 貢獻方式

新增或修改 skill 前，請先閱讀 [`CONTRIBUTING.md`](CONTRIBUTING.md)。PR 需至少包含：

- skill 資料夾與 `SKILL.md`
- `skills.json` catalog 更新
- 必要時加入 `evals/evals.json`
- 通過 `npm run validate`

## 授權

MIT。詳見 [`LICENSE`](LICENSE)。
