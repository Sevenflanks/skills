// Local-only fixture: the CLI exits while its child keeps a loopback listener.
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { spawn } = require('node:child_process');

const [mode, root, token, lifetimeArg, exitDelayArg] = process.argv.slice(2);
const at = (name) => path.join(root, name);
const write = (name, data) => fs.writeFileSync(at(name), JSON.stringify(data));

if (mode === 'baseline') {
  write('baseline.json', { status: 'exited' });
} else if (mode === 'launch') {
  const launchStartedUtc = new Date().toISOString();
  const child = spawn(process.execPath, [__filename, 'child', root, token, lifetimeArg, exitDelayArg], {
    cwd: root, detached: true, stdio: 'ignore', windowsHide: true,
  });
  child.on('error', (error) => { console.error(error); process.exitCode = 1; });
  child.unref();
  write('launcher.json', { childPid: child.pid, token, launchStartedUtc });
} else if (mode === 'stop') {
  const binding = JSON.parse(fs.readFileSync(at('launcher.json'), 'utf8'));
  if (binding.token !== token || !fs.existsSync(at('ready.json'))) {
    throw new Error('No matching current-run owner binding');
  }
  const ready = JSON.parse(fs.readFileSync(at('ready.json'), 'utf8'));
  if (ready.token !== token || ready.pid !== binding.childPid) {
    throw new Error('Descendant binding does not match readiness');
  }
  fs.writeFileSync(at('stop.token'), token);
} else if (mode === 'child') {
  const lifetime = Number(lifetimeArg);
  if (!Number.isInteger(lifetime) || lifetime < 1000 || lifetime > 10000) {
    throw new Error('Test-only lifetime must be between 1000 and 10000 ms');
  }
  const exitDelay = Number(exitDelayArg);
  if (!Number.isInteger(exitDelay) || exitDelay < 0 || exitDelay > 500) {
    throw new Error('Test-only exit delay must be between 0 and 500 ms');
  }
  let finished = false;
  // Leave the connection open: server.close(callback) cannot be the hard deadline.
  const server = net.createServer((socket) => socket.write(`${token}\n`));
  const finish = (reason) => {
    if (finished) return;
    finished = true;
    clearInterval(poll);
    write('child-exit-intent.json', { pid: process.pid, reason });
    // Test-only delay exposes the interval between intent and actual OS exit.
    if (reason === 'owner-stop' && exitDelay) setTimeout(() => process.exit(0), exitDelay);
    else process.exit(0);
  };
  // Never clear this independent deadline: even an open socket or interrupted harness cannot stall it.
  const deadline = setTimeout(() => {
    if (!finished) write('child-exit-intent.json', { pid: process.pid, reason: 'fixture-deadline' });
    process.exit(0);
  }, lifetime);
  const poll = setInterval(() => {
    try {
      if (fs.readFileSync(at('stop.token'), 'utf8') === token) finish('owner-stop');
    } catch (error) {
      if (error.code !== 'ENOENT') finish('stop-read-error');
    }
  }, 25);
  server.listen(0, '127.0.0.1', () => {
    write('ready.json', { token, pid: process.pid, port: server.address().port });
  });
  server.on('error', (error) => finish(`listen-error:${error.code}`));
} else {
  throw new Error(`Unknown fixture mode: ${mode}`);
}
