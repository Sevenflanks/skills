import { execFile as execFileCallback } from 'node:child_process';
import process from 'node:process';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);

export const OPENCODE_EXECUTABLE = 'C:\\nvm4w\\nodejs\\opencode.cmd';

export function createOpenCodeInvocation(args) {
  if (!Array.isArray(args) || !args.includes('--pure')) {
    throw new Error('Every OpenCode benchmark command must enable --pure');
  }
  return { executable: OPENCODE_EXECUTABLE, args: [...args] };
}

export async function executeOpenCode(args, { cwd = process.cwd() } = {}) {
  const invocation = createOpenCodeInvocation(args);
  return execFile(invocation.executable, invocation.args, {
    cwd,
    maxBuffer: 10 * 1024 * 1024,
    shell: true,
    windowsHide: true,
  });
}
