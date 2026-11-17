import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { native } from './index.js';
const shell = join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe');
const dir = await mkdtemp(join(tmpdir(), 'dsh-background-test-'));
const ready = join(dir, 'hwnd.txt'), result = join(dir, 'text.txt');
const fixture = spawn(shell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', join(process.cwd(), 'background-fixture.ps1'), '-ReadyPath', ready, '-ResultPath', result], { windowsHide: true, stdio: 'ignore' });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const waitFor = async (path, expected) => {
  for (let i = 0; i < 60; i++) {
    const value = await readFile(path, 'utf8').catch(() => undefined);
    if (value === expected) return value;
    await sleep(50);
  }
  return await readFile(path, 'utf8').catch(() => undefined);
};
let summary, failure;
try {
  let hwnd = 0;
  for (let i = 0; i < 150 && !hwnd; i++) { await sleep(100); hwnd = Number(await readFile(ready, 'utf8').catch(() => '0')); }
  assert(hwnd > 0, 'fixture window did not start');
  const tree = await native('inspect', { hwnd, limit: 60, depth: 4 });
  const button = tree.controls.find(c => c.name === 'Verify');
  assert(button, 'fixture button was not exposed');
  assert(tree.controls.some(c => (c.class_name || '').startsWith('WindowsForms10.EDIT')), 'fixture text field was not exposed');
  const typed = await native('background_act', { hwnd, operation: 'type', text: 'background ok' });
  assert.equal(typed.supported, true, `typing should stay in the background: ${typed.reason}`);
  assert.equal(typed.background_observation.foreground_unchanged, true, 'typing must not move focus');
  assert.equal(await waitFor(result, 'background ok'), 'background ok', 'the classic control must receive the text');
  const clicked = await native('background_act', { hwnd, operation: 'click', selector: { name: 'Verify' } });
  assert.equal(clicked.supported, true, `clicking should stay in the background: ${clicked.reason}`);
  assert.equal(clicked.background_observation.foreground_unchanged, true, 'clicking must not move focus');
  assert.equal(await waitFor(`${result}.button`, 'clicked'), 'clicked', 'the button must run its handler');
  const key = await native('background_act', { hwnd, operation: 'key', key: 'End' });
  assert.equal(key.supported, true, `keys should stay in the background: ${key.reason}`);
  const shot = await native('screenshot', { hwnd, path: join(dir, 'window.png'), mode: 'background' });
  assert(shot.width > 0 && shot.height > 0);
  summary = { passed: true, background_typing: true, background_click_by_selector: true, background_keys: true, focus_never_moved: true, cropped_screenshot: true, warm_call_ms: typed.backend_ms };
} catch (error) {
  failure = error;
}
fixture.kill();
await sleep(150);
if (failure) { console.error(failure.message); process.exit(1); }
console.log(JSON.stringify(summary));
process.exit(0);
