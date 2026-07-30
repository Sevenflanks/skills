# 04 — 實作安靜且低成本的 stage-one self-challenge

**What to build:** 在已鎖定 benchmark 與 release thresholds 下，建立 `self-challenge` 的 stage-one 核心流程，讓 Agent 在 direction-changing edit 前先快速檢查候選作法與 confirmed intent 的關係，而不把日常執行變成公開 ceremony。

**Blocked by:** 03 — 鎖定人工 release thresholds 與 benchmark 成本授權

**Status:** ready-for-agent

- [ ] `skills/self-challenge/SKILL.md` 建立有效 frontmatter，`name` 為 `self-challenge`，版本先維持未發布的 `0.1.0` candidate。
- [ ] Stage one 僅在 pivot cues 出現時啟動，並於任何 direction-changing edit 前完成；routine execution 與明確 within-intent 修正不得一律升級。
- [ ] Stage one 辨認 decision-relevant evidence、candidate action、exact confirmed-intent traceability、可能改變的 commitment、可觀察 falsifier 與 lower-commitment alternative。
- [ ] 流程明確區分 implementation/test/environment defect 與 invalidated plan assumption，並採可推翻的保守推定而非盲目守舊。
- [ ] Stage-one-only benchmark 依鎖定配置執行；調整只能使用 training partition，true held-out 不得用來調 prompt。
- [ ] 正常成功保持安靜；只有必要的方向性結果、證據缺口或既有 user-owned directional decision 才公開說明或詢問。
- [ ] 本 ticket 不實作 stage-two sub-agent、failure/reentry policy、registry publication 或對外效果宣稱。
