# skills

這是個人維護的 Agent Skills 倉庫，用來集中管理可重用的 OpenCode／Claude-style skills。

此倉庫會隨時間加入更多 skills。每個 skill 都放在 [`skills/`](skills/) 底下獨立的資料夾中，並以 `SKILL.md` 作為主要定義檔；若有測試或評估案例，則放在該 skill 自己的 `evals/` 目錄中。

## 目前收錄的 skills

| Skill | 說明 | 路徑 |
| --- | --- | --- |
| `gh-body-file` | 在 Windows、PowerShell、OpenCode shell 環境中，安全使用 GitHub CLI 支援 `--body-file` 的指令。 | [`skills/gh-body-file/`](skills/gh-body-file/) |

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

## 倉庫結構

```text
skills/
└── gh-body-file/
    ├── SKILL.md
    └── evals/
        └── evals.json
```

- Skill 定義檔：[`skills/gh-body-file/SKILL.md`](skills/gh-body-file/SKILL.md)
- 評估案例：[`skills/gh-body-file/evals/evals.json`](skills/gh-body-file/evals/evals.json)

## 安裝方式

依照你的 agent runtime 支援的方式安裝 GitHub-hosted skill；或直接將需要的 skill 資料夾複製到本機 skills 目錄。

以 OpenCode-style 的本機安裝為例，可複製 [`skills/gh-body-file/`](skills/gh-body-file/) 到你的 skills 目錄，使目標資料夾至少包含：

```text
gh-body-file/
├── SKILL.md
└── evals/
    └── evals.json
```

## 新增 skill 的慣例

未來新增 skill 時，請使用以下結構：

```text
skills/
└── <skill-name>/
    ├── SKILL.md
    └── evals/
        └── evals.json   # 選用
```

並同步更新本 README 的「目前收錄的 skills」表格。

## 授權

MIT。詳見 [`LICENSE`](LICENSE)。
