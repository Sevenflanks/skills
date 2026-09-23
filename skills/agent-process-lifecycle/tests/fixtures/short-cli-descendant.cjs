// Local-only fixture: the CLI exits while its child keeps a loopback listener.
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const { spawn } = require('node:child_process');

const [mode, root, token, lifetimeArg] = process.argv.slice(2);
const at = (name) => path.join(root, name);
const write = (name, data) => fs.writeFileSync(at(name), JSON.stringify(data));

if (mode === 'baseline') {
  write('baseline.json', { status: 'exited' });
} else if (mode === 'launch' || mode === 'launch-no-ready') {
  const launchStartedUtc = new Date().toISOString();
  const childMode = mode === 'launch-no-ready' ? 'child-no-ready' : 'child';
  const child = spawn(process.execPath, [__filename, childMode, root, token, lifetimeArg], {
    cwd: root, detached: true, stdio: 'ignore', windowsHide: true,
  });
  child.on('error', (error) => { console.error(error); process.exitCode = 1; });
  child.unref();
  write('launcher.json', { childPid: child.pid, token, launchStartedUtc, mode });
} else if (mode === 'stop' || mode === 'release') {
  const binding = JSON.parse(fs.readFileSync(at('launcher.json'), 'utf8'));
  const evidence = binding.mode === 'launch-no-ready' ? 'child-started.json' : 'ready.json';
  if (binding.token !== token || !fs.existsSync(at(evidence))) {
    throw new Error('No matching current-run owner binding');
  }
  const child = JSON.parse(fs.readFileSync(at(evidence), 'utf8'));
  if (child.token !== token || child.pid !== binding.childPid) {
    throw new Error('Descendant binding does not match child evidence');
  }
  if (mode === 'release') {
    const intent = JSON.parse(fs.readFileSync(at('child-exit-intent.json'), 'utf8'));
    if (intent.pid !== binding.childPid || intent.reason !== 'owner-stop') {
      throw new Error('Owner-stop intent does not match binding');
    }
  }
  fs.writeFileSync(at(`${mode}.token`), token);
} else if (mode === 'child' || mode === 'child-no-ready') {
  const lifetime = Number(lifetimeArg);
  if (!Number.isInteger(lifetime) || lifetime < 1000 || lifetime > 10000) {
    throw new Error('Test-only lifetime must be between 1000 and 10000 ms');
  }
  let finished = false;
  // Leave the connection open: server.close(callback) cannot be the hard deadline.
  const server = mode === 'child' ? net.createServer((socket) => socket.write(`${token}\n`)) : null;
  const finish = (reason) => {
    if (finished) return;
    finished = true;
    write('child-exit-intent.json', { pid: process.pid, reason });
    // Owner-stop waits for the caller to observe intent and explicitly release it.
    // The independent hard deadline below remains active even without that ack.
    if (reason !== 'owner-stop') process.exit(0);
  };
  // Never clear this independent deadline: even an open socket or interrupted harness cannot stall it.
  const deadline = setTimeout(() => {
    if (!finished) write('child-exit-intent.json', { pid: process.pid, reason: 'fixture-deadline' });
    process.exit(0);
  }, lifetime);
  const poll = setInterval(() => {
    try {
      if (fs.readFileSync(at(finished ? 'release.token' : 'stop.token'), 'utf8') === token) {
        if (finished) process.exit(0);
        else finish('owner-stop');
      }
    } catch (error) {
      if (error.code !== 'ENOENT') finish('owner-token-read-error');
    }
  }, 25);
  if (server) {
    server.listen(0, '127.0.0.1', () => {
      write('ready.json', { token, pid: process.pid, port: server.address().port });
    });
    server.on('error', (error) => finish(`listen-error:${error.code}`));
  } else {
    // 啟動證據僅用來綁定本次 child 的 Stop；不能當作 readiness。
    write('child-started.json', { token, pid: process.pid });
  }
} else {
  throw new Error(`Unknown fixture mode: ${mode}`);
}
