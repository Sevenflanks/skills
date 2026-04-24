# skills

這是個人維護的 Agent Skills 倉庫，用來集中管理可重用的 OpenCode／Claude-style skills。

此倉庫會隨時間加入更多 skills。每個 skill 都放在 [`skills/`](skills/) 底下獨立的資料夾中，並以 `SKILL.md` 作為主要定義檔；若有測試或評估案例，則放在該 skill 自己的 `evals/` 目錄中。

## 目前收錄的 skills

| Skill | 版本 | 狀態 | 說明 | 路徑 |
| --- | --- | --- | --- | --- |
| `gh-body-file` | `0.1.0` | stable | 在 Windows、PowerShell、OpenCode shell 環境中，安全使用 GitHub CLI 支援 `--body-file` 的指令。 | [`skills/gh-body-file/`](skills/gh-body-file/) |
| `playwright-server-lifecycle` | `0.1.0` | stable | 管理 Playwright/browser 驗證所需的本機 dev server 背景啟動、PID/log、ready check 與 cleanup。 | [`skills/playwright-server-lifecycle/`](skills/playwright-server-lifecycle/) |

完整 catalog 可見 [`skills.json`](skills.json)。若需要 Claude plugin-style metadata，可見 [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json)。新增、調整或移除 skill 時，請同步更新 catalog 並執行驗證。

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

## playwright-server-lifecycle

`playwright-server-lifecycle` 會引導 agent 在使用 Playwright、browser automation、截圖或 UI smoke test 前，把本機 dev server 當成需要 lifecycle 管理的資源。它要求先檢查 port、用背景／detached process 啟動長時間 server、導出 stdout/stderr log、記錄 PID/port、以 ready check 驗證服務可用，並在測試完成後停止本次啟動的 server、確認 port 已釋放。

適用於容易卡住 agent session 的情境，例如：

- `pnpm dev`
- `npm run dev`
- `nuxt dev`
- `vite`
- `next dev`
- Tomcat 或其他長時間 web server

此 skill 特別針對 Windows／PowerShell／OpenCode shell 中以前景模式啟動 dev server 造成 session 卡住，或用 timeout 假裝背景啟動後留下殘留 process 的問題。

## 倉庫結構

```text
skills/
├── gh-body-file/
│   ├── README.md
│   ├── SKILL.md
│   └── evals/
│       └── evals.json
└── playwright-server-lifecycle/
    ├── README.md
    ├── SKILL.md
    └── evals/
        └── evals.json
```

- `gh-body-file` 說明文件：[`skills/gh-body-file/README.md`](skills/gh-body-file/README.md)
- `gh-body-file` 定義檔：[`skills/gh-body-file/SKILL.md`](skills/gh-body-file/SKILL.md)
- `gh-body-file` 評估案例：[`skills/gh-body-file/evals/evals.json`](skills/gh-body-file/evals/evals.json)
- `playwright-server-lifecycle` 說明文件：[`skills/playwright-server-lifecycle/README.md`](skills/playwright-server-lifecycle/README.md)
- `playwright-server-lifecycle` 定義檔：[`skills/playwright-server-lifecycle/SKILL.md`](skills/playwright-server-lifecycle/SKILL.md)
- `playwright-server-lifecycle` 評估案例：[`skills/playwright-server-lifecycle/evals/evals.json`](skills/playwright-server-lifecycle/evals/evals.json)

## 安裝方式

依照你的 agent runtime 支援的方式安裝 GitHub-hosted skill；或直接將需要的 skill 資料夾複製到本機 skills 目錄。

以 OpenCode-style 的本機安裝為例，可複製需要的 skill 資料夾到你的 skills 目錄，使目標資料夾至少包含：

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
        └── evals.json   # 選用
```

並同步更新本 README 的「目前收錄的 skills」表格、[`skills.json`](skills.json)，以及 [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json)。

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
