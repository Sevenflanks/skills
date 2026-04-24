# Skills Repo 架構

此 repo 採用「一個資料夾一個 skill」的 collection 架構，方便未來加入更多 skills，同時維持可搜尋、可驗證、可安裝。

## 目錄設計

```text
.
├── skills.json
├── .claude-plugin/
│   └── marketplace.json
├── skills/
│   └── <skill-name>/
│       ├── README.md
│       ├── SKILL.md
│       └── evals/
│           └── evals.json
├── templates/
├── scripts/
└── docs/
```

## 根目錄檔案

- `README.md`：給使用者看的入口文件與 skills 索引。
- `skills.json`：機器可讀的 skills catalog。
- `.claude-plugin/marketplace.json`：Claude plugin-style distribution metadata，記錄每個 skill 的 source、description、version、keywords。
- `CONTRIBUTING.md`：新增或修改 skill 的流程。
- `AGENTS.md`：給 agent 的長期維護規則。
- `scripts/validate-skills.mjs`：本地與 CI 共用的驗證腳本。
- `.github/workflows/validate.yml`：在 push / pull request 時執行驗證。

## Skill 資料夾

每個 skill 以 `skills/<skill-name>/` 為單位：

```text
skills/<skill-name>/
├── README.md
├── SKILL.md
└── evals/
    └── evals.json
```

`README.md` 是人類閱讀的使用說明；`SKILL.md` 是 runtime 主要讀取的檔案。`evals/evals.json` 是選用但建議保留的評估案例，可協助驗證 skill 行為是否符合預期。

## Catalog

`skills.json` 是 repo 的機器可讀索引。它讓 README、驗證腳本與未來自動化工具能用一致來源理解目前有哪些 skills。

新增 skill 時，至少應更新：

1. `skills/<skill-name>/SKILL.md`
2. `skills/<skill-name>/README.md`
3. `skills.json`
4. `.claude-plugin/marketplace.json`
5. `README.md`
6. `evals/evals.json`（若有可驗證行為）
