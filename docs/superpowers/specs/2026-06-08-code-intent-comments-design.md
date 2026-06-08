# code-intent-comments 設計規格

## 背景

要新增一個 Agent Skill：`code-intent-comments`。

這個 skill 的目的不是要求 agent 到處補註解，而是讓 agent 在開發程式時，主動補上人類工程師讀程式時最需要的脈絡。這些脈絡通常是程式碼本身看不出來，或需要追很久才會知道的內容，例如：為什麼這樣寫、這段邏輯不能簡化的原因、使用者特殊需求、舊資料相容、高風險區間、商業規則的例外。

使用者希望註解風格參考兩個既有專案：

- `C:\develop\projects\cardif-ifrs17-migrate`
- `C:\develop\projects\softleader-erp-nex`

但這不是要照抄兩個專案目前的註解數量。使用者也明確補充：過去有些註解沒有寫足夠，這個 skill 的目的之一就是補足這些不足。

因此本 skill 的標準是：繼承使用者偏好的註解語氣與關注點，並比既有專案更主動補上維護者需要知道的原因、限制與風險。

## 設計目標

`code-intent-comments` 要引導 agent 寫「意圖型註解」。

意圖型註解回答的是：

- 這段程式為什麼存在？
- 為什麼要這樣寫？
- 不這樣做會出什麼問題？
- 這是正式設計、暫時解法，還是舊資料相容？
- 哪些地方看起來可以簡化，但其實不能簡化？
- 這段邏輯影響哪些下游或使用者需求？

這個 skill 不追求提高註解密度，而是提高註解價值。

## 使用者註解風格

保留的風格：

- 以繁體中文為主，技術名詞、檔名、class、method、欄位、指令保留原文。
- 語氣像工程備忘錄，不像教學文章。
- 直接說明原因、限制、風險與取捨。
- 常用白話句型，例如「因為...所以...」、「避免...」、「目前...」、「暫時...」、「若...則...」。
- 可以記錄 `User要求`、`CR`、日期、`TODO`、`FIXME`，但不能只留下標籤。

需要微調的風格：

- 用詞要白話，不要把註解寫成艱澀技術文件。
- 不可濫用縮寫。只有專案內已普遍使用、或程式碼本身就是該縮寫時才使用，例如 `DB`、`API`、`CR`。第一次出現較不常見的縮寫時，應補上完整意思或更白話的說法。
- `User要求` 要盡量補上誰、何時、哪個需求，避免只有當下寫的人看得懂。
- `TODO`、`FIXME` 要說明現況、風險、代價或修正時機。
- 高風險區要補「不要改掉的原因」，避免未來維護者誤以為可以簡化。
- class/module 註解要補責任邊界，也要說明不負責什麼。
- 收斂過度口語或玩笑式註解，改成穩定的工程語氣。

## 什麼時候要寫註解

### 既有註解不足時

如果本次修改的程式碼附近已經有註解，但註解不足、太口語、太模糊或已經無法正確說明現況，agent 可以主動改寫。

限制：

- 只改本次 touched code 附近的註解。
- 只改與理解、風險、使用者需求、CR、相容性或維護脈絡直接相關的註解。
- 不做全檔註解整理。
- 不為了純粹統一語氣或格式而改遠處註解。
- 不把註解改成更艱澀的技術文件；仍要維持白話、可讀。

這條規則是為了補足過去註解沒有寫夠的地方，不是要求 agent 順手大掃除。

### class 或 module 層級

需要在人類工程師打開檔案時，快速知道這個 class/module 的責任、邊界與禁忌。

應補：

- 這個 class/module 負責什麼。
- 不負責什麼。
- 誰會呼叫它，或它位在什麼流程中。
- 有哪些不能誤用的地方。

不應補：

- 只把 class 名稱翻成中文。
- 重述 framework 類型，例如「這是一個 Controller」。

### 核心 method 或特殊 method

當 method 內有核心流程、非典型邏輯、失敗策略、副作用、狀態轉換、資料修補、分攤、排序依賴、快取、重試或外部整合時，要補 method 或區塊註解。

應補：

- 這段流程保護什麼規則。
- 失敗時為什麼要中斷或不中斷。
- 有哪些副作用。
- 哪些輸入假設成立。
- 為什麼這段不能改成看起來更簡單的寫法。

### 使用者需求、CR 與決策

遇到使用者特殊需求、CR、使用者確認過的行為、舊資料相容、歷史決策、臨時解法時，要補註解。

好的註解應包含：

- 需求來源或時間。
- 需求造成的非直觀行為。
- 舊行為與新行為的差異。
- 未來修改時需要保留的限制。

範例語氣：

```java
// 2026-03 CR-123 User要求舊資料仍顯示 ALL，因此這裡保留 default 轉換，避免歷史資料出現在下拉選單時失去對應。
```

### 高風險區間

以下區域要比既有專案更主動補註解：

- 金額、比例、rounding、尾差分攤。
- 冪等、重跑、差額補正、reversal、offset。
- 狀態轉換與流程中斷條件。
- 併發、鎖、同步點。
- DB 寫入穩定性、排序穩定性、批次資料穩定性。
- 下游欄位污染、資料來源不一致、內外部命名差異。
- legacy 流程、framework 怪癖、舊資料相容。
- 效能、記憶體、長時間任務、非阻斷失敗策略。

## 什麼不要寫

禁止寫低資訊量註解，例如：

```java
// 初始化
// 檢核
// 呼叫商業邏輯
```

禁止寫同義註解，例如：

```java
private String reason; // 請假原因
```

禁止大量補沒有資訊增量的 `@param` 或 `@return`。

禁止把舊程式碼註解掉當作歷史保存。

禁止直譯程式碼，例如：

```java
// 如果 amount 大於 0 就加到 total
if (amount.compareTo(BigDecimal.ZERO) > 0) {
  total = total.add(amount);
}
```

## 註解品質檢查

每個註解至少要回答下列其中一題：

- 為什麼這段存在？
- 不這樣寫會壞在哪裡？
- 哪個使用者需求或 CR 導致這段邏輯？
- 這段保護什麼商業規則？
- 這段有哪些外部限制或歷史包袱？
- 未來維護者可能誤改哪裡？
- 這段是暫時解法還是正式設計？

如果一個註解沒有回答任何一題，agent 應刪掉或改寫。

## Skill 內容設計

`SKILL.md` 結構建議：

1. frontmatter
2. Overview
3. When to use
4. Do not use when
5. Comment decision gate
6. Personal style profile
7. What to comment
8. What not to comment
9. Comment templates
10. Examples
11. Common mistakes
12. Final checklist

frontmatter：

```yaml
---
name: code-intent-comments
description: Use when adding or changing code where future maintainers need plain-language comments about class responsibility, core logic, unusual decisions, user CRs, compatibility, risk, or why code must not be simplified.
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.0
---
```

描述要偏觸發條件，不要把完整流程塞進 description。

## Repo 變更範圍

實作時需要新增或更新：

- `skills/code-intent-comments/SKILL.md`
- `skills/code-intent-comments/README.md`
- `skills/code-intent-comments/evals/evals.json`
- `skills.json`
- `.claude-plugin/marketplace.json`
- `README.md`

版本使用 `0.1.0`。

author 使用 `sevenflankse`。

license 使用 `MIT`。

tags/keywords 建議：

- `comments`
- `documentation`
- `maintainability`
- `code-review`
- `intent`
- `risk`
- `cr`

## 測試設計

這個 skill 屬於行為型 skill，需要 eval。

建議 eval cases：

1. 修改高風險金額分攤或 rounding 邏輯。
   - 期待 agent 補上商業不變量、尾差落點、不可簡化原因。
   - 不期待逐行解釋加總或 if 判斷。

2. 新增 class 或 service，處理舊資料相容或使用者 CR。
   - 期待 class summary 說明責任與邊界。
   - 期待 CR 註解白話說明需求來源與相容原因。

3. 修改簡單 config 或 typo。
   - 期待 agent 不過度觸發，不新增沒必要註解。

4. 新增 framework workaround 或 legacy 整合。
   - 期待註解說明 framework 怪癖、正式或暫時性、未來移除條件。

5. 修改已有但不足的註解。
   - 期待只改本次 touched code 附近、且和理解或風險直接相關的註解。
   - 不期待全檔註解統一語氣或格式。

## 成果展示

整個 skill 完成後，需要挑幾段程式碼展示套用後的效果。

展示可以使用小型前後對照或純套用後片段，但要清楚表現：

- class/module 責任與邊界註解。
- 核心或特殊 method 的原因、限制或不可簡化原因。
- 使用者需求、CR、舊資料相容或高風險區註解。
- 簡單變更不需要註解的反例。

展示用程式碼片段應避免直接修改參考專案，除非使用者另行要求。預設只放在回報或 skill 文件範例中。

## 驗證

完成實作後執行：

```powershell
npm run validate
```

已知陷阱：既有 `skills/daily-work-log/SKILL.md` 可能因 frontmatter 行尾格式造成 validator 失敗。新檔應使用 LF，避免新增同類問題。若 validate 失敗且原因來自既有檔案，需明確標示為既有問題，不把它混成新 skill 的問題。

## 開放問題

目前無阻塞開放問題。實作前只需使用者確認此設計。
