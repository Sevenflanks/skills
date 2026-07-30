import { spawn } from 'node:child_process';
import process from 'node:process';

export const OPENCODE_EXECUTABLE = 'C:\\nvm4w\\nodejs\\opencode.cmd';
export const OPENCODE_TIMEOUT_MS = 120_000;

export function createOpenCodeInvocation(args) {
  if (!Array.isArray(args) || !args.includes('--pure')) {
    throw new Error('Every OpenCode benchmark command must enable --pure');
  }
  return { executable: OPENCODE_EXECUTABLE, args: [...args] };
}

function collect(stream) {
  let output = '';
  stream.setEncoding('utf8');
  stream.on('data', (chunk) => {
    output += chunk;
  });
  return () => output;
}

export async function terminateOpenCodeProcessTree(pid, { spawnProcess = spawn } = {}) {
  if (!Number.isInteger(pid) || process.platform !== 'win32') {
    return;
  }
  await new Promise((resolve) => {
    const killer = spawnProcess('taskkill.exe', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true });
    killer.once('error', resolve);
    killer.once('close', resolve);
  });
}

export function launchOpenCode(args, {
  cwd = process.cwd(),
  spawnProcess = spawn,
  terminateProcessTree = terminateOpenCodeProcessTree,
  timeoutMs = OPENCODE_TIMEOUT_MS,
} = {}) {
  const invocation = createOpenCodeInvocation(args);
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawnProcess(invocation.executable, invocation.args, {
        cwd,
        shell: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
      });
    } catch (error) {
      reject(error);
      return;
    }
    const stdout = collect(child.stdout);
    const stderr = collect(child.stderr);
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      void terminateProcessTree(child.pid);
    }, timeoutMs);
    child.once('error', (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.once('close', (exitCode, signal) => {
      clearTimeout(timeout);
      resolve({
        exitCode: Number.isInteger(exitCode) ? exitCode : 1,
        signal: signal ?? null,
        stderr: stderr(),
        stdout: stdout(),
        timedOut,
      });
    });
  });
}

export function executeOpenCode(args, options) {
  return launchOpenCode(args, options);
}
