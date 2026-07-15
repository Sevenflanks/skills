---
name: playwright-server-lifecycle
description: Use when Playwright or browser automation needs a local listener, temporary HTTP server, static viewer, dev or preview server, or Windows/PowerShell/OpenCode work shows hangs, zombies, unclear process ownership, cleanup failures, or missing callbacks.
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.1
---

# Playwright Server Lifecycle

Treat every listener created for browser work as a current-run resource. Record its ownership before browser work, report browser completion separately from success, then reconcile only that recorded tree.

## Gate 1: Classify Before Creating a Listener

Classify the target before running any command that could listen, including dev servers, preview servers, temporary HTTP servers, `python -m http.server`, `py -3.11 -m http.server`, and static viewers.

- For self-contained static HTML, navigate Playwright to `file://` first. Do not create a server when the file, its inline assets, and the requested interaction work directly.
- For a listener, inspect the target port and classify any existing owner as external or current-run. Reuse an external owner only when user intent permits it. Never terminate it, include it in cleanup, or start a duplicate listener on its port.
- Never run a listener in the foreground or treat a timeout as background execution. Start only with a detached launcher, redirect logs, then prove readiness by port or HTTP condition.
- Create a current-run ownership record before browser work: command shape, launcher PID, observed wrapper PID or PIDs, listener PID and port, log paths, and the record location. `powershell -> py.exe -> python.exe` is an example tree shape, not a fixed command or PID list.

One concise Windows pattern is a detached PowerShell wrapper, not the listener in the agent shell:

```powershell
$launcher = Start-Process powershell -ArgumentList "-NoProfile -Command Set-Location 'C:\path\to\app'; py -3.11 -m http.server 3917 --bind 127.0.0.1 1> .server.log 2> .server.err.log" -WindowStyle Hidden -PassThru
```

**Completion criterion:** either `file://` is selected with no listener needed, or a detached listener strategy records its expected port, any existing-owner decision, command, launcher, wrappers, listener, logs, and current-run ownership before browser work starts.

## Gate 2: Report Browser Completion and Result Separately

Define success criteria before navigation. Capture URL, visible or accessibility evidence, screenshot when requested, console errors, page errors, and network failures.

Report two independent fields:

- `completed`: the requested navigation, interaction, screenshot, or check finished.
- `passed`: the evidence met the task's success criteria.

Classify every error as `blocking` or `non-blocking`. A blocking error changes `passed` to `false` even if `completed` is `true`. For example, navigation, clicking Save, and a screenshot can finish while `null.toFixed()` blocks page behavior, so report `completed=true`, `passed=false`, and list that error as blocking. A third-party-cookie warning that does not affect the requested title or visible balance is non-blocking and may leave `passed=true`, but still belongs in the report.

**Completion criterion:** browser evidence contains `completed`, `passed`, separate blocking and non-blocking error lists, and URL, screen, or accessibility evidence sufficient to judge each success criterion.

## Gate 3: Cleanup and Callback in Finally

Put browser close, current-run reconciliation, port release verification, and the parent-agent callback in `finally`. Run them after every outcome, including readiness failure, blocking browser failure, and cleanup failure.

- Close the page and browser first.
- Reconcile only the recorded current-run launcher, wrapper, and listener tree. If the listener exits first, recover recorded wrappers or launchers that remain as current-run orphans. If the launcher exits first, recover the recorded listener. Do not kill by name, port-only lookup, or broad scan.
- Record the final state of every tracked launcher, wrapper, and listener. Verify the target port is released after reconciliation.
- If ownership cannot be proven or the port remains occupied, stop automatic termination. Preserve command, owner, PID, port, and log evidence, then report the unresolved state without claiming cleanup succeeded.

The final callback reports the ownership decision, browser `completed` and `passed` results, blocking and non-blocking errors, final state of each recorded process, port-release result, log or screenshot evidence, and unresolved owners or artifacts. An external owner has no current-run cleanup or port-release claim.

**Completion criterion:** the parent-agent callback is delivered after `finally` records browser closure, every recorded process's final state, port-release status, evidence paths, and any unresolved ownership or cleanup failure.
