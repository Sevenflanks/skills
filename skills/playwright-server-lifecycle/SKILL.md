---
name: playwright-server-lifecycle
description: Use when Playwright or browser automation needs a local dev server, UI preview, screenshot target, login-page check, or smoke test server, especially on Windows/PowerShell/OpenCode where foreground `pnpm dev`, Vite, Nuxt, Next, Tomcat, or preview commands can hang/freeze the agent session, timeout leaves zombie processes, or PID/port/log cleanup is required.
license: MIT
metadata:
  author: sevenflankse
  version: 0.1.0
---

# Playwright Server Lifecycle

This skill keeps browser verification from freezing the agent session or leaving zombie dev servers. Treat a local server as a resource with a lifecycle: discover, start in the background, verify readiness, use Playwright, then stop and prove the port is released.

## When to use

Use this skill when:

- A task needs Playwright, browser automation, screenshots, or UI smoke testing and the app is not already running.
- You are about to run `pnpm dev`, `npm run dev`, `vite`, `nuxt dev`, `next dev`, `preview`, Tomcat, or another long-running server.
- The shell is Windows, PowerShell, OpenCode, or another environment where foreground servers can block the session.
- You need to report server PID/port/logs or clean up a server you started.

Do not use this skill when:

- You are only running finite commands such as `pnpm build`, `pnpm test`, or `mvn test`.
- The user explicitly asks to keep a server running after the task. Still record PID, port, logs, and the reason.

## Core rule

Never start a long-running server in the foreground. Do not run `pnpm dev` and rely on timeout to escape. A timeout is not background execution; it often leaves unclear process state.

## Workflow

1. **Inspect existing state**
   - Check whether the expected port is already listening.
   - If it is already listening, identify the owner and decide whether to reuse it instead of starting a duplicate.

2. **Prepare logs and PID tracking**
   - Choose stdout/stderr log files in the app directory or another task-local location.
   - If you start a server, capture both the launcher PID and the actual listening PID/port.
   - Prefer writing a PID file when the repo has a standard location for it.

3. **Start detached from the agent shell**
   - On Windows/PowerShell, start a separate hidden PowerShell process and run the dev server inside it.
   - Redirect stdout and stderr to files.
   - Avoid `Start-Process pnpm -RedirectStandardOutput ...` for Node package-manager shims when it has not been proven in that environment; launching a child PowerShell is usually safer because the agent shell returns after spawning the OS-owned process.

4. **Wait by condition, not hope**
   - Poll the target port or HTTP endpoint until ready.
   - If readiness fails, read the logs before changing commands.

5. **Run Playwright/browser verification**
   - Navigate to the target URL.
   - Capture objective evidence: URL, title, accessibility snapshot text, console errors/warnings, network failures, or screenshot path when useful.

6. **Always clean up what you started**
   - Close the browser/page.
   - Stop the listening process that belongs to this run.
   - Confirm the target port no longer listens.
   - Remove temporary screenshots or MCP artifacts unless the user asked to keep them.

## Windows / PowerShell pattern

Adapt paths, port, and logs to the repo. This example starts a Nuxt UI server from the repo root.

```powershell
# 1. Check existing listener first
Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort, OwningProcess

# 2. Start in a detached hidden PowerShell; do not run pnpm dev directly in the agent shell
$arg = "-NoProfile -ExecutionPolicy Bypass -Command Set-Location 'C:\path\to\repo\ui'; pnpm dev 1> .playwright-ui-dev.log 2> .playwright-ui-dev.err.log"
$launcher = Start-Process powershell -ArgumentList $arg -WindowStyle Hidden -PassThru

# 3. Wait for the actual listener
$listener = $null
for ($i = 0; $i -lt 80; $i++) {
  Start-Sleep -Milliseconds 250
  $listener = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($listener) { break }
}

[pscustomobject]@{
  LauncherPid = $launcher.Id
  PortReady = [bool]$listener
  Port = $(if ($listener) { $listener.LocalPort } else { $null })
  OwningProcess = $(if ($listener) { $listener.OwningProcess } else { $null })
  StdoutLog = 'ui\.playwright-ui-dev.log'
  StderrLog = 'ui\.playwright-ui-dev.err.log'
}
```

Stop only the server you started or the listener you positively identified for this run:

```powershell
$listener = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
  Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1
Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
```

## Required checks

Before Playwright:

- Target port checked before starting.
- Server started with a detached/background mechanism, not foreground plus timeout.
- stdout and stderr are redirected to log files.
- Readiness is proven by port or HTTP check.

After Playwright:

- Browser/page is closed.
- Server started by the agent is stopped unless the user explicitly asks to keep it.
- Target port release is verified.
- Final report includes command shape, URL reached, evidence observed, PID/port/logs, cleanup result, and any non-blocking warnings.

## Common mistakes

| Mistake | Why it is unsafe | Correct behavior |
| --- | --- | --- |
| Running `pnpm dev` directly | Blocks the session indefinitely | Spawn a detached/background process |
| Using timeout as escape hatch | May leave unclear process state | Start background, then stop explicitly |
| Starting a duplicate server | Pollutes ports and confuses verification | Check existing listener first |
| Killing by port without ownership thinking | Can stop a server the user wanted kept | Track PID or only stop this run's listener |
| Ignoring logs when readiness fails | Leads to guessing | Read stdout/stderr before changing approach |
| Leaving screenshots/MCP artifacts | Pollutes working tree | Clean artifacts unless requested |

## Report template

```text
Server lifecycle:
- Pre-check: <port state>
- Started: <command shape>, launcher PID <pid>, listener PID/port <pid>/<port>, logs <paths>
- Browser evidence: <URL/title/key visible text/console/network summary>
- Cleanup: <browser closed, server stopped, port released>
- Remaining artifacts: <none or paths intentionally kept>
```
