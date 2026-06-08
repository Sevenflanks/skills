# code-intent-comments

`code-intent-comments` 會引導 agent 在寫程式時補上人類工程師需要的意圖型註解。它不鼓勵到處寫註解，而是聚焦 class 責任、核心邏輯、特殊決策、User 要求、CR、舊資料相容與高風險區間。

## 解決的問題

程式碼可以看出「做了什麼」，但常看不出「為什麼這樣做」。這個 skill 補足維護者需要知道的脈絡，例如不可簡化原因、尾差規則、相容性、暫時解法與風險邊界。

## 使用時機

- 新增或修改 class/module 責任與邊界。
- 修改核心 method、特殊流程、金額/rounding/冪等/狀態轉換。
- 處理 User 要求、CR、舊資料相容、legacy 或 framework workaround。
- 本次 touched code 附近有不足、過時或模糊的既有註解。

簡單 typo、格式調整、明顯 config rename 不需要套用，除非有外部相容風險。

## 主要流程

1. 先判斷程式碼本身是否已能說明意圖。
2. 只在程式碼無法表達原因、限制或風險時補註解。
3. 用白話繁中說明「為什麼」與「不要誤改什麼」。
4. 既有註解只改本次 touched code 附近，且必須和理解、風險或需求脈絡直接相關。
5. 最後刪掉低資訊量註解，例如 `初始化`、`檢核`、同義欄位註解。

## 檔案

- [`SKILL.md`](SKILL.md)：skill 定義與工作規則。
- [`evals/evals.json`](evals/evals.json)：行為評估案例。
