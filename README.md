# skills

這是個人維護的 Agent Skills 倉庫，用來集中管理可重用的 OpenCode／Claude-style skills。

此倉庫會隨時間加入更多 skills。每個 skill 都放在 [`skills/`](skills/) 底下獨立的資料夾中，並以 `SKILL.md` 作為主要定義檔；若有測試或評估案例，則放在該 skill 自己的 `evals/` 目錄中。

## 目前收錄的 skills

| Skill | 版本 | 狀態 | 說明 | 路徑 |
| --- | --- | --- | --- | --- |
| `code-intent-comments` | `0.1.0` | stable | 引導 agent 以白話繁中撰寫高價值程式註解，補足 class 責任、核心邏輯、CR、相容性與高風險脈絡。 | [`skills/code-intent-comments/`](skills/code-intent-comments/) |
| `daily-work-log` | `0.7.0` | stable | 合併 OpenCode／Codex 與 Git／GitHub 證據；Codex metadata、SQLite history 與 exact JSONL 有界補證，依 canonical repo 查 issue 狀態並揭露缺口。 | [`skills/daily-work-log/`](skills/daily-work-log/) |
| `erp-daily-work-log` | `0.4.1` | stable | 依工作證據與 canonical repo／issue 狀態填報；只刷新失效補證並保留 preview／授權流程。 | [`skills/erp-daily-work-log/`](skills/erp-daily-work-log/) |
| `gh-body-file` | `0.1.1` | stable | 在 Windows、PowerShell、OpenCode shell 環境中，安全使用 GitHub CLI 支援 `--body-file` 的指令。 | [`skills/gh-body-file/`](skills/gh-body-file/) |
| `agent-process-lifecycle` | `1.1.1` | stable | 管理可能卡住或跨越 tool call 的本機 process；Windows 同 tool Stop 採當次 owner cleanup 契約，跨 tool Preserve 才需背景返回；缺證據的特殊路由可診斷；non-Windows 僅分類、handoff 或 launch 前 blocked。 | [`skills/agent-process-lifecycle/`](skills/agent-process-lifecycle/) |
| `finish-and-admin-merge` | `0.1.2` | stable | 依最新 PR、review 與 checks 證據執行已授權的 admin squash merge，並安全收尾 branch／worktree。 | [`skills/finish-and-admin-merge/`](skills/finish-and-admin-merge/) |
| `generate-ut-report` | `0.1.1` | stable | 依時間區間與自然語言條件，產生有來源證據且格式固定的靜態 UT HTML 報告。 | [`skills/generate-ut-report/`](skills/generate-ut-report/) |
| `make-function-manual-sop` | `0.1.1` | stable | 以版本、實機畫面與欄位證據製作操作說明書，依可用 renderer 驗證並交付。 | [`skills/make-function-manual-sop/`](skills/make-function-manual-sop/) |
| `opencode-db-prune` | `0.3.0` | stable | 完整保留或近期 30 天的激進精簡；Deja 選用且自動偵測，未安裝仍可用兩種模式。 | [`skills/opencode-db-prune/`](skills/opencode-db-prune/) |
| `push-post-pr` | `0.1.1` | stable | 確認工作完成後，依授權 commit／push 並發布繁中 PR，核對 title、本文與交付狀態。 | [`skills/push-post-pr/`](skills/push-post-pr/) |
| `start-from-matt` | `0.1.2` | stable | 透過外部 ask-matt 建議流程，預設維持討論與決策，確認開發授權後才進入實作。 | [`skills/start-from-matt/`](skills/start-from-matt/) |
| `to-spec-or-ticket` | `0.1.1` | stable | 判斷需求應產生 spec 或 tickets，載入選中流程；不適合時僅提出下一步建議。 | [`skills/to-spec-or-ticket/`](skills/to-spec-or-ticket/) |
| `write-design-spec-for-user-confirm` | `0.1.1` | stable | 以使用者與 UI 語言，撰寫需求背景、功能與操作流程導向的 -srs Markdown 文件。 | [`skills/write-design-spec-for-user-confirm/`](skills/write-design-spec-for-user-confirm/) |

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

`daily-work-log` 先用固定 PowerShell collector 的 `-ProbeOnly` 探測 OpenCode／Codex，向使用者預告來源與略過理由，再合併本機活動、`git log --all` 與相關 GitHub PR／issue 證據。Codex 以 metadata 找候選、SQLite history 按 item 時間精選，再用 exact JSONL 補證；Python 3.11+ 為必要，已核對的 `0.164.0-alpha.11.1` 僅作 reference contract，不因 Codex 版本不同、未知或缺少版本而拒絕、降級或產生相容性草稿，依實際 schema／時間／內容與安全 indexed query 能力處理。SQL／JSONL 額度分開揭露，有限涵蓋與相容性缺口不推論完整 recall；無來源或讀取全失敗時停止。Collector stdout 維持純 JSON，由 agent 去重相同工作主題，輸出優先依 GitHub repo name 分組的每日工作日誌。

適用於需要整理今日或指定時間範圍的工作摘要，例如：

- 從 OpenCode session 反推今天實際工作的 repo。
- 收集不限 branch 的 git commits。
- 使用 `gh` 補充 PR 編號與 closing issue 關聯。
- 輸出適合直接貼到 standup / 日報的簡短條列。

若 `gh` 不可用或未登入，此 skill 會要求 agent 預設先停止並建議安裝 GitHub CLI 或執行 `gh auth login`；只有使用者強烈堅持時才降級繼續並保留 PR / issue 補證缺口。repo 非 git、或 session 有進入但沒有 commit 時，也會要求 agent 保留資料缺口說明，而不是直接忽略。

## erp-daily-work-log

`erp-daily-work-log` 結合 `daily-work-log` 的 probe／預告／collect 與外部唯讀 `erp` skill 的本人 context、請假及日期 mapping。預設列完整預覽再確認；官方 append 可用時首次填寫／已有日誌均可補新增。只有明確替換才走 replace，保留獨立覆蓋授權及次日 10:00 期限；整日請假不 collect、不寫日誌。

`0.3.0` 支援可信未生效證據下一次受控 retry、確認啟用後的個人偏好記憶，仍核對當日官方 project／module／RD 參照。共用 repo mapping 儲存另有差異預覽／授權，維護不受日誌 deadline／請假 gate 影響，不宣稱跨端點 atomic。

Python standard-library helpers 預設 dry-run，分別固定本人日誌 append／replace 與 mapping POST／PUT，tests 已接入 `npm run validate`。每次執行須先讀官方 OpenAPI，開發契約不代表部署已支援；缺 mapping 維護 API 只停用儲存。配置沿用外部 ERP skill 的 config root／X-API-KEY，不複製外部 skill，也不改上游 collector；詳見 [`skills/erp-daily-work-log/README.md`](skills/erp-daily-work-log/README.md)。

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

Windows self-managed helper 可在 caller 已獲授權的專案目錄內建立受保護的本次 artifact，而不修改既有 ACL 或要求完整 ancestor ACL audit。readiness 期間也會觀察本次保留的 root handle，讓 candidate early exit 與 bind error 不會退化成單純 timeout。

Launch 前先選擇 `Stop` 或 `Preserve`。`Stop` 必須有 live identity-bound ownership proof；`Preserve` 必須指定 later owner 並交付 fresh binding、record、stdio、readiness 與日後的 Stop 方法。`Preserve` 是 responsibility handoff，不是 cleanup 完成。

`1.1.1` 僅在 Windows 執行 lifecycle。non-Windows 僅做 bounded 分類：可辨識 owner 時 handoff，否則在 launch 前 blocked；不做 OS inspection、lifecycle shell call、launch 或 termination。

## opencode-db-prune

`opencode-db-prune` 用於磁碟回收與每月維護。先快速健檢、按需完整估算，明確授權後才在 OpenCode 全部退出時重建、驗證並切換。預設 `compact` 完整保留所有內容；明確選用 `aggressive` 才保留最近 30 天（720 小時）完整 session，較舊內容依已確認規則精簡。Deja 是自動偵測的選用整合，未安裝也能使用兩種模式。

Python standard-library helper 建立獨立 plan，再分別 build/promote，預設保留原檔、可另行 verified purge；inspect-run 支援唯讀診斷未完成操作。核對 schema、內容、外鍵、檔案身分與 preserve paths。Windows 支援離線寫入，其他 OS 僅唯讀估算；未知 schema 會拒絕，激進模式另拒絕非空替代 store。較舊 session 不保證完整續跑／還原，月清仍會累積保留資料。用法與恢復方式見 [`skills/opencode-db-prune/README.md`](skills/opencode-db-prune/README.md)。

## OpenCode command 遷移

新增七個同名 skill，保留已確認流程，按需要將長契約拆到 references；安裝時複製整個資料夾。

這七個 skill 均僅限人工明確觸發：Codex 使用 `$skill-name`，Claude Code 使用 `/skill-name`。每個 `SKILL.md` 設定 `disable-model-invocation: true`，並隨套件提供 `agents/openai.yaml`，設定 `policy.allow_implicit_invocation: false`；兩者都是 skill 的 metadata。設定語意可見 [Claude Code invocation control](https://code.claude.com/docs/en/skills#control-who-invokes-a-skill) 與 [Codex invocation policy](https://learn.chatgpt.com/docs/build-skills#optional-metadata)。

- `finish-and-admin-merge`、`push-post-pr`：最新 PR 證據、明確授權與自足的交付回報。
- `generate-ut-report`：固定 HTML／回覆契約；沿用原 UT 計數規則並記錄 class-summary 限制。
- `make-function-manual-sop`：版本與實機證據、欄位／操作覆蓋、依環境可用 renderer 進行 QA。
- `start-from-matt`、`to-spec-or-ticket`：外部 Matt 流程依賴與核准邊界，不包含其原文。
- `write-design-spec-for-user-confirm`：使用者／UI 語言的 `-srs.md` 文件。

這七個入口依實際 pwsh／bash 執行環境選擇語法，不依賴 `git-master` 或個人工具路徑。多行 PR 本文與 title 驗證範例可見 [shell 執行與本文傳遞](skills/push-post-pr/references/shell-execution.md)。可重複使用的 skill 資料夾至少含 SKILL.md、README.md、agents/openai.yaml、evals；兩個長文件流程另含 references，詳細檔案與依賴由各 skill README 說明。

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
├── erp-daily-work-log/
│   ├── SKILL.md
│   ├── README.md
│   ├── references/helper.md
│   ├── scripts/daily_report.py
│   ├── tests/test_daily_report.py
│   └── evals/evals.json
├── opencode-db-prune/
│   ├── SKILL.md
│   ├── README.md
│   ├── references/
│   ├── scripts/
│   ├── tests/
│   └── evals/evals.json
├── gh-body-file/
│   ├── README.md
│   ├── SKILL.md
│   └── evals/
│       └── evals.json
├── agent-process-lifecycle/
│   ├── README.md
│   ├── SKILL.md
│   ├── evals/
│   │   └── evals.json
│   ├── references/
│   │   ├── failure-and-handoff.md
│   │   └── windows-self-managed.md
│   └── scripts/
│       ├── Invoke-AgentProcessLifecycle.ps1
│       └── JobHandleHolder.ps1
├── finish-and-admin-merge/
│   └── agents/
│       └── openai.yaml
├── generate-ut-report/
│   └── agents/
│       └── openai.yaml
├── make-function-manual-sop/
│   └── agents/
│       └── openai.yaml
├── push-post-pr/
│   └── agents/
│       └── openai.yaml
├── start-from-matt/
│   └── agents/
│       └── openai.yaml
├── to-spec-or-ticket/
│   └── agents/
│       └── openai.yaml
└── write-design-spec-for-user-confirm/
    └── agents/
        └── openai.yaml
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
