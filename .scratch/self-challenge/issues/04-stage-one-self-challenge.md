# 04 — 實作安靜且低成本的 stage-one self-challenge

**What to build:** 在已鎖定 benchmark 與 release thresholds 下，建立 `self-challenge` 的 stage-one 核心流程，讓 Agent 在 direction-changing edit 前先快速檢查候選作法與 confirmed intent 的關係，而不把日常執行變成公開 ceremony。

**Blocked by:** 03 — 鎖定人工 release thresholds 與 benchmark 成本授權

**Status:** needs-info

**Claimed by:** current OpenCode session on `feature/plan-reflection-skill`

- [x] `skills/self-challenge/SKILL.md` 建立有效 frontmatter，`name` 為 `self-challenge`，版本先維持未發布的 `0.1.0` candidate。
- [x] Stage one 僅在 pivot cues 出現時啟動，並於任何 direction-changing edit 前完成；routine execution 與明確 within-intent 修正不得一律升級。
- [x] Stage one 辨認 decision-relevant evidence、candidate action、exact confirmed-intent traceability、可能改變的 commitment、可觀察 falsifier 與 lower-commitment alternative。
- [x] 流程明確區分 implementation/test/environment defect 與 invalidated plan assumption，並採可推翻的保守推定而非盲目守舊。
- [ ] Stage-one-only benchmark 依鎖定配置執行；調整只能使用 training partition，true held-out 不得用來調 prompt。
- [x] 正常成功保持安靜；只有必要的方向性結果、證據缺口或既有 user-owned directional decision 才公開說明或詢問。
- [x] 本 ticket 不實作 stage-two sub-agent、failure/reentry policy、registry publication 或對外效果宣稱。

## Comments

- Candidate、stage-one adapter/controller、canonical exported-assistant evidence parser、strict training gate 與 deterministic 30-slot fake execution 已完成；`npm run validate` 通過 49/49。
- Live stage-one-only training 是 final 180-run matrix 之外的 30 個額外 main runs（6 tracked training scenarios × 5 fresh trials），無 retry，單次 OpenCode operation timeout boundary 為 120 秒。此額外成本尚未取得明確授權，因此未執行。
- Held-out integrity incident：Ticket 04 implementing sub-agent 與後續 read-only reviewer 的廣域 `rg` exclude pattern 失效，各自曾輸出 private fixture 的 matching lines。內容未被用於 candidate 調整，coordinator 也未開啟 private fixture，但原 locked true-held-out partition 已無法再證明未向 candidate development context 揭露。
- 原 true-held-out partition 已 quarantined，不得用於 release claim、candidate tuning 或 Ticket 08 final evidence。不得靜默替換 Ticket 03 的 immutable manifest；需由使用者明確決定在 candidate freeze 後以獨立 context 建立並重新鎖定 replacement partition，或將原 partition 降級為 disclosed evaluation。
- Ticket 05 維持 blocked，直到本票 live training 與 held-out integrity decision 完成。
