# 使用契約：Windows self-managed lifecycle helper

這份 reference 描述 Windows self-managed helper 的 model-facing contract。只有在 `SKILL.md` 已選定 Windows self-managed tier 後，且在 pre-launch validation 與 `Launch`／`Finalize` 前才讀取它。

## 適用條件

只有在 Windows，且 workload 可由同一個 session、相容的 security context 啟動與後續管理時，才使用這個 helper。caller 必須能提供固定且新鮮的 `RecordPath`，並保留 helper 回傳的 opaque `binding`。`binding` 不可自行解讀、拼接或替換；record 是 authority-bearing helper artifact，不能當成一般狀態快取。

同一個 lifecycle owner 必須序列化對同一 record 的 `Finalize` 呼叫。helper 不提供 concurrent CAS guarantee，因此不可讓多個 owner 同時 Finalize。

## 公開操作：`Launch` 與 `Finalize`

Public actions 只有：

* `Launch`，建立並驗證 workload 的 lifecycle binding。
* `Finalize`，依 `Disposition` 完成收尾。`Preserve` 是 `Finalize` 的 disposition，不是第三個 action。

### 啟動：`Launch`

Launch 至少需要 executable、`ArgumentList`、working directory、stdout/stderr paths、readiness identity、readiness context、readiness check、readiness deadline、`RecordPath` 與 `RequestedDisposition`。

`RequestedDisposition` 可為 `Stop` 或 `Preserve`。選 `Preserve` 時必須提供 `RequestedLaterOwner`。選 `Stop` 時不可提供 `RequestedLaterOwner`。readiness 必須在有限 deadline 內成功，否則 Launch fail closed，不交付可用 binding。

Launch 的 live evidence 只代表 preflight 當下觀察到的狀態，不是未來仍然有效的保證。成功時，caller 應保存回傳的 opaque `binding`、`RecordPath`、stdio、readiness 與 lifecycle result。

### 收尾：`Finalize`

Finalize 需要 `RecordPath` 與 `Disposition`。`Disposition` 可為 `Stop` 或 `Preserve`。

`Disposition: Preserve` 必須提供與 handoff 中相符的 `LaterOwner`。Preserve 只能重新驗證 ownership 並交付日後管理所需的 opaque binding、record、stdio、readiness、later owner 與 safe `stop_method`，不得終止 workload。`LaterOwner` 只是責任標籤，不是 credential，也不能單獨授權 Stop。

`Disposition: Stop` 不接受 `LaterOwner`。它可以接受 `GracefulAction`、`GracefulContext` 與 bounded `GracefulDeadlineMilliseconds`，但 graceful inputs 只對 Stop 有效。Stop 應先嘗試 graceful 收尾；若 graceful 未完成，才使用已驗證 authority 做 forced Stop。Preserve 不得帶 graceful inputs。

Preserve 回傳的 `stop_method` 必須是可安全轉交的 opaque handoff，且具有：

```text
action: "Finalize"
disposition: "Stop"
record_path: <同一個 RecordPath>
```

後續 Stop 必須在新的 invocation 中，以這個 handoff 與 record 重新驗證 ownership，並由新的 compatible owner 執行 fresh later Stop。不得以 caller 自行保存的瞬時狀態猜測要終止的 workload。

## 結果契約

結果至少分開描述：

* `action`、`tier`、`requested_disposition`、`final_disposition`、`later_owner`、`binding`、`stdio`、`readiness`、`stop_method` 與 `evidence`，這些是 lifecycle helper 的結果。
* `lifecycle_result`，描述 lifecycle operation、`status`、cleanup 結果及失敗或 unresolved 原因。
* `downstream_result`，由 caller 傳入並原樣保留，描述 downstream work，不代表 lifecycle cleanup 成功，也不會因 lifecycle rejection 被改寫。

成功 Stop 應回報 graceful 或 forced operation、resource result，並移除 handoff record。成功 Preserve 應保持 workload 與 authority 可供 later Stop 使用，並將 `final_disposition.status` 設為 preserved。被拒絕或無法證明 authority 時，`lifecycle_result.status` 為 `unresolved`，不得執行 graceful action、forced termination 或猜測性 cleanup；record 與 workload 應保持不變，直到能安全重新驗證。

Preserve 可能有 mixed result：若已證明 handoff 的 atomic publication 成功，只有 exact temporary artifact cleanup 尚未完成，則 `lifecycle_result.status` 可為 `unresolved`，但 `final_disposition.status` 仍為 `preserved`。此時 caller 或 later owner 必須照常接收 `later_owner` 與 safe `stop_method`，並在新的 invocation 執行 later Stop；成功的 later Stop 也必須清除該 record 所精確界定的 temporary residue。若 publication 仍是 original-unchanged 或狀態 unknown，不得宣稱成功 handoff，也不得交付可供 later Stop 使用的 Preserve 結果。

Preserve 交付的是責任轉移，不是 credential 轉移。若 later owner 不在同一 session 或不具相容的 security context，或任一必要 live evidence 在重新驗證時不成立，helper 必須 safe rejection/unresolved，而不是降級成 PID 或名稱式停止。

## 明確限制

此 helper 不保證 atomic publication 完成前發生 abrupt host crash 時，能自動恢復或判定所有 lifecycle 狀態。

此 helper 也不保證能抵抗同一 user security context 下，對 record 或 named object 的惡意 tampering。這兩項情況都必須視為 non-guarantee，不得在 model-facing guidance 中暗示 helper 提供更高的完整性保證。
