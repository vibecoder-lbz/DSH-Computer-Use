import { spawn } from 'node:child_process';
import { open, readFile, writeFile, mkdtemp, rm, mkdir, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
const root = dirname(fileURLToPath(import.meta.url));
const shell = join(process.env.SystemRoot || 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe');
const specs = JSON.parse(await readFile(join(root, 'schemas.json'), 'utf8'));
export const inject = ['tools', 'attachments', 'userQuestions'];
const exists = async path => { try { await access(path); return true; } catch { return false; } };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const object = properties => ({ type: 'object', properties, additionalProperties: false });
const integer = description => ({ type: 'integer', description });
const string = description => ({ type: 'string', description });
const selector = { type: 'object', properties: { ref: string('Runtime reference from the latest inspect.'), automation_id: string('Exact AutomationId.'), name: string('Exact case-sensitive name.'), control_type: string('Exact ControlType, such as ControlType.Button.') }, additionalProperties: false };
const operation = { type: 'string', enum: ['invoke', 'set_value', 'select', 'click', 'move', 'type', 'key', 'scroll'] };

export async function native(action, params, signal) {
  signal?.throwIfAborted();
  const dir = await mkdtemp(join(tmpdir(), 'dsh-hybrid-call-'));
  let out, err;
  try {
    const request = join(dir, 'request.json'), response = join(dir, 'response.json');
    await writeFile(request, JSON.stringify({ action, params }), 'utf8');
    out = await open(join(dir, 'out.log'), 'w'); err = await open(join(dir, 'err.log'), 'w');
    return await new Promise((resolve, reject) => {
      const child = spawn(shell, ['-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-File', join(root, 'native.ps1'), '-RequestPath', request, '-ResponsePath', response], { windowsHide: true, stdio: ['ignore', out.fd, err.fd] });
      let stopped = false;
      const stop = () => { stopped = true; child.kill(); };
      const timer = setTimeout(stop, 35000);
      signal?.addEventListener('abort', stop, { once: true });
      if (signal?.aborted) stop();
      const clean = () => { clearTimeout(timer); signal?.removeEventListener('abort', stop); };
      child.once('error', error => { clean(); reject(error); });
      child.once('close', async () => {
        clean();
        if (stopped) return reject(new Error('Operation interrupted; inspect current state before retrying.'));
        try {
          const data = JSON.parse((await readFile(response, 'utf8')).replace(/^\uFEFF/, ''));
          if (!data.ok) throw new Error(data.error);
          resolve(data.result);
        } catch (error) { reject(error); }
      });
    });
  } finally { await out?.close(); await err?.close(); await rm(dir, { recursive: true, force: true }); }
}

export function apply(ctx) {
  let queue = Promise.resolve(), lease, disposed = false, stopVersion = 0;
  const tickets = new Map();
  const serial = work => { const next = queue.then(work); queue = next.catch(() => {}); return next; };
  const ownerOf = exec => exec.agent?.id || 'unowned';
  async function release(reason = 'released') {
    stopVersion++;
    const current = lease;
    if (!current) return { active: false, reason };
    lease = undefined;
    clearTimeout(current.timer);
    await writeFile(join(current.dir, 'stop'), reason).catch(() => {});
    current.overlay.kill();
    // Retain a tiny diagnostic state rather than deleting a directory the overlay may still be reading.
    return { active: false, reason, hwnd: current.hwnd };
  }
  async function current(exec) {
    if (lease && (Date.now() >= lease.expiresAt || await exists(join(lease.dir, 'stop')) || lease.overlay.exitCode !== null)) await release('stopped_or_expired');
    if (lease && lease.owner !== ownerOf(exec)) throw new Error('Another session owns desktop takeover.');
    return lease;
  }
  const output = { schema: { type: 'object', additionalProperties: true }, render(_args, value) { const { image, ...details } = value; return [{ type: 'text', text: JSON.stringify(details) }, ...(image ? [{ type: 'image', attachment: image }] : [])]; } };
  function register(name, description, parameters, execute) {
    ctx.effect(() => ctx.tools.register({ name, description, parameters, output, timeoutMs: 180000, isConcurrencySafe: () => false,
      execute: (args, exec) => serial(async () => { exec.signal.throwIfAborted(); if (disposed) throw new Error('Plugin unloaded'); return execute(args, exec); }),
    }));
  }
  for (const spec of specs.filter(spec => ['apps', 'windows', 'inspect', 'wait', 'compare', 'screenshot'].includes(spec.name))) {
    const action = spec.name;
    register(`computer_${action}`, action === 'screenshot'
      ? 'Capture a target window in the background with PrintWindow. With this session’s active takeover, capture visible pixels. Inspect for blank or stale GPU content.'
      : spec.description, action === 'screenshot' ? { ...spec.input_schema, required: ['hwnd'] } : spec.input_schema,
      async (args, exec) => {
        const params = { ...args };
        if (action === 'screenshot') {
          const active = await current(exec);
          params.mode = active?.hwnd === args.hwnd ? 'foreground' : 'background';
          params.path = resolve(args.path || join(tmpdir(), `dsh-hybrid-${randomUUID()}.png`));
          await mkdir(dirname(params.path), { recursive: true });
        }
        const result = await native(action, params, exec.signal);
        if (action !== 'screenshot') return result;
        const image = await ctx.attachments.saveImage({ data: await readFile(result.path), mediaType: 'image/png', name: 'Computer window.png' });
        return { ...result, image };
      });
  }
  const actParams = { ...object({ hwnd: integer('Target window handle from computer_windows.'), operation,
    selector, value: string('Text for set_value.'), x: integer('Window-relative physical pixel x for click/move.'), y: integer('Window-relative physical pixel y for click/move.'),
    text: string('Unicode text to type, at most 2000 characters.'), key: string('Supported key or shortcut, e.g. Enter, Tab, Escape, Ctrl+A.'), delta: integer('Wheel delta, normally 120 or -120.') }), required: ['hwnd', 'operation'] };
  register('computer_act', 'Try a background control operation first. Unsupported actions return takeover_required and a ticket; they never silently activate the desktop. After approved takeover, actions target that window. Verify results after every action.', actParams,
    async (args, exec) => {
      if (!Number.isSafeInteger(args.hwnd) || args.hwnd <= 0) throw new Error('Invalid hwnd');
      if (!operation.enum.includes(args.operation)) throw new Error('Unknown operation');
      const active = await current(exec);
      if (active) {
        if (active.hwnd !== args.hwnd) throw new Error('Release current window takeover before changing target.');
        try { return await native('foreground_act', { ...args, statePath: active.statePath }, exec.signal); }
        catch (error) { await release('input_failed'); throw error; }
      }
      const result = await native('background_act', args, exec.signal);
      if (!result.takeover_required) return result;
      const ticket = randomUUID();
      for (const [key, value] of tickets) if (Date.now() > value.expiresAt) tickets.delete(key);
      tickets.set(ticket, { owner: ownerOf(exec), hwnd: args.hwnd, reason: result.reason || 'No background interface', expiresAt: Date.now() + 300000 });
      return { ...result, ticket, next: 'Call computer_takeover begin with this ticket; user consent precedes desktop activation.' };
    });
  register('computer_takeover', 'Begin visible takeover only after a background attempt returned a ticket. The user confirms in Harness; a light-blue gradient border and pointer trail mark control. Ctrl+Alt+Esc stops. Release when done; status reports current lease.',
    { ...object({ action: { type: 'string', enum: ['begin', 'status', 'release'] }, ticket: string('Ticket returned by computer_act when takeover_required.'), seconds: integer('Lease duration, 15–120 seconds; default 60. No automatic renewal.') }), required: ['action'] },
    async (args, exec) => {
      if (args.action === 'release') return release('agent_released');
      if (args.action === 'status') { const active = await current(exec); return { active: !!active, ...(active ? { hwnd: active.hwnd, expiresAt: active.expiresAt, stop: 'Ctrl+Alt+Esc' } : {}) }; }
      if (args.action !== 'begin') throw new Error('Unknown takeover action');
      if (await current(exec)) throw new Error('Takeover already active');
      const ticket = tickets.get(args.ticket);
      if (!ticket || ticket.owner !== ownerOf(exec) || Date.now() >= ticket.expiresAt) throw new Error('Missing or expired background attempt ticket');
      const seconds = args.seconds ?? 60;
      if (!Number.isInteger(seconds) || seconds < 15 || seconds > 120) throw new Error('seconds must be 15–120');
      const window = (await native('windows', {}, exec.signal)).windows.find(w => w.hwnd === ticket.hwnd);
      if (!window) throw new Error('Target window no longer exists');
      const version = stopVersion;
      const answer = await ctx.userQuestions.ask({ agent: exec.agent, signal: exec.signal, wait: { callId: exec.callId }, questions: [{ id: 'desktop-takeover', header: '桌面接管', question: `后台接口无法完成操作。允许 agent 接管「${window.title || ticket.hwnd}」${seconds} 秒吗？`, detail: '接管时会移动鼠标、使用键盘并切换到目标窗口。淡蓝色渐变边框及轨迹会显示控制范围；Ctrl+Alt+Esc 随时停止。', options: [{ label: '允许本次接管' }, { label: '保持后台，不接管' }] }] });
      if (!answer.answers?.find(item => item.id === 'desktop-takeover')?.selected?.includes('允许本次接管')) return { active: false, reason: 'User did not approve takeover' };
      exec.signal.throwIfAborted();
      if (disposed || version !== stopVersion) return { active: false, reason: 'Takeover cancelled by stop or unload' };
      tickets.delete(args.ticket);
      const dir = await mkdtemp(join(tmpdir(), 'dsh-takeover-')), statePath = join(dir, 'state.json');
      const expiresAt = Date.now() + seconds * 1000;
      await writeFile(statePath, JSON.stringify({ hwnd: ticket.hwnd, active: true, expiresAt, trail: [] }), 'utf8');
      const overlay = spawn(shell, ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', join(root, 'overlay.ps1'), '-StatePath', statePath, '-OwnerPid', String(process.pid)], { windowsHide: true, stdio: 'ignore' });
      overlay.on('error', () => { if (lease?.overlay === overlay) void release('overlay_failed'); });
      lease = { owner: ownerOf(exec), hwnd: ticket.hwnd, expiresAt, dir, statePath, overlay };
      lease.timer = setTimeout(() => { void release('expired'); }, seconds * 1000);
      try {
        let ready;
        for (let i = 0; i < 100; i++) { exec.signal.throwIfAborted(); if (await exists(join(dir, 'overlay-ready.json'))) { ready = true; break; } if (overlay.exitCode !== null) break; await delay(100); }
        if (!ready) throw new Error('Overlay did not become ready; takeover cancelled');
        await native('prepare', { hwnd: ticket.hwnd, statePath }, exec.signal);
        return { active: true, hwnd: ticket.hwnd, expiresAt, stop: 'Ctrl+Alt+Esc', visual: 'Light-blue gradient border and fading agent pointer trail' };
      } catch (error) { await release('takeover_failed'); throw error; }
    });
  // Stop is intentionally not queued behind slow inspection or user confirmation.
  ctx.effect(() => ctx.tools.register({ name: 'computer_stop', description: 'Immediately stop this plugin’s desktop takeover and remove its overlay. Can be called from any session.', parameters: object({}), output, timeoutMs: 5000, isConcurrencySafe: () => true, execute: async () => release('user_or_agent_stop') }));
  ctx.effect(() => () => { disposed = true; tickets.clear(); void release('plugin_unloaded'); });
}
