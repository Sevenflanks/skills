---
name: code-intent-comments
description: Use when adding or changing code with class responsibilities, core business logic, unusual decisions, user CRs, compatibility, legacy behavior, or high-risk areas where future maintainers may need plain-language context, even if the user did not explicitly ask for comments.
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.0
---

# Code Intent Comments

## Overview

寫註解是為了留下維護者需要的脈絡，不是把程式碼翻成中文。

好註解說明「為什麼」與「不要誤改什麼」：責任邊界、核心規則、特殊使用者需求、舊資料相容、風險、暫時解法、不可簡化原因。

## When to Use

當程式變更碰到以下內容時使用：

- class/module 責任、邊界、禁忌。
- 核心 method、特殊流程、非典型邏輯。
- User 要求、CR、使用者確認過的行為。
- 舊資料相容、legacy 流程、framework 怪癖。
- 金額、rounding、尾差、冪等、狀態轉換、reversal、offset。
- 併發、鎖、同步點、長時間任務、非阻斷失敗策略。
- DB 寫入、排序穩定性、下游欄位污染、資料來源不一致。
- 既有註解不足、模糊、太口語，且位置在本次 touched code 附近。

純 typo、格式調整、明顯 config rename，或名稱與測試已經能說清楚的程式碼，不需要使用這個 skill。

## Comment Decision Gate

新增或改寫註解前，先問：

1. Code alone看得出這段為什麼存在嗎？
2. 未來維護者可能把這段改成看似更簡單但錯的寫法嗎？
3. 這段有使用者需求、CR、相容性、風險或歷史取捨嗎？
4. 註解能不能回答「不這樣做會怎樣」？

如果答案全部是否定，就不要加註解。

## Existing Comment Rewrite Gate

可改既有註解，但只能在這些條件都成立時改：

- 註解在本次 touched code 附近。
- 註解和理解、風險、使用者需求、CR、相容性或維護脈絡直接相關。
- 既有註解不足、過時、太模糊、太口語，或會讓人誤解現況。

不要做全檔註解整理。不要為了純粹統一語氣或格式而改遠處註解。

## Personal Style Profile

使用白話繁中。技術名稱保留原文，例如 class、method、field、API、DB、CR、command、error message。

避免濫用縮寫。只有程式碼或團隊語言已經常用的縮寫才保留；如果縮寫可能讓讀者誤解，就改成完整白話。

語氣像工程備忘錄，不像正式文章。可用這些句型：

- `因為...所以...`
- `避免...`
- `目前...`
- `暫時...`
- `若...則...`
- `不可改成...，因為...`

`TODO` 與 `FIXME` 可以用，但必須包含現況原因、風險與何時回頭處理。

## What to Comment

### Class or Module Responsibility

說明責任與邊界。若未來容易誤用，也要說明它不負責什麼。

```java
/**
 * 將舊 campaign 設定轉成畫面顯示值。
 * 只處理 display value 相容，不負責驗證；驗證仍在 CampaignValidator。
 */
class CampaignDisplayValueMapper {
}
```

### Core or Special Method Logic

說明規則、副作用、失敗策略或不變量。

```java
// 前 n-1 筆正常 rounding，最後一筆承接尾差，確保下游會計總額仍等於原始總額。
// 不可改成每筆 rounding 後再加總，否則尾差會消失。
```

### User Requirement, CR, Compatibility

補足脈絡，讓讀者就算一時找不到 CR，也能理解這段為什麼存在。

```java
// 2026-03 CR-123 User要求畫面顯示 ALL；舊資料仍存 default，所以只在顯示層轉換，不回寫 DB。
```

### Risky Temporary or Framework Workaround

說明這是暫時解法還是正式設計、為什麼存在，以及什麼條件下可以移除。

```ts
// Nuxt hydration 期間 auth store 可能尚未初始化，這裡先用 cookie 還原登入狀態。
// 待 server-side session 統一後可移除這段 fallback。
```

## What Not to Comment

不要加低資訊量流程標籤：

```java
// 初始化
// 檢核
// 呼叫商業邏輯
```

不要重述名稱已經說清楚的事：

```java
private String reason; // 請假原因
```

不要把舊程式碼註解掉當歷史保存。Git 已經保留歷史。

不要逐行翻譯程式碼：

```java
// 如果 amount 大於 0 就加到 total
if (amount.compareTo(BigDecimal.ZERO) > 0) {
  total = total.add(amount);
}
```

簡單 typo 或 config 變更不加註解，除非有外部相容風險。

```java
// 不加註解：maxRetires -> maxRetries 是單純 typo 修正，diff 與測試名稱已經足夠說明。
config.setMaxRetries(value);
```

## Common Mistakes

| 常見錯誤 | 修正方式 |
| --- | --- |
| 只寫 `最後一筆吃尾差` | 補上為什麼不能簡化，以及它保護哪個下游不變量。 |
| 只寫 `依 CR-123 顯示 ALL` | 補上 `default` 是舊資料儲存值、`ALL` 是顯示值，以及是否會回寫 DB。 |
| 加上 `// fixed typo from maxRetires` | 刪掉。diff 與測試已經能說明 typo 修正。 |
| 順手改完整個檔案的註解 | 停止。只改 touched code 附近、且和風險或脈絡相關的註解。 |
| 用很多縮寫讓註解看起來很技術 | 改用白話。只保留專案常用詞或識別名稱。 |
| 只寫 `TODO` 沒寫風險 | 補原因、風險與回頭處理條件，否則移除 TODO。 |

## Final Checklist

完成程式變更前，檢查：

- [ ] 新增的高風險 class/module 若名稱不足以說明用途，是否有簡短責任與邊界註解？
- [ ] 核心或特殊 method 是否說明不變量、副作用或失敗策略？
- [ ] CR/User requirement 註解是否提供 ticket 編號以外的必要脈絡？
- [ ] 暫時 workaround 是否說明存在原因與可移除條件？
- [ ] 是否避免替純 typo、明顯 config、自明程式碼加註解？
- [ ] 是否避免整理無關既有註解？
- [ ] 註解是否維持白話繁中、保留技術名稱，且縮寫不影響閱讀？
