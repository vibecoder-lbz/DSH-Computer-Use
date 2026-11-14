import { spawn } from 'node:child_process';
import { open, readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const root = dirname(fileURLToPath(import.meta.url));
const specs = JSON.parse(await readFile(join(root, 'tool-schemas.json'), 'utf8'));
export const inject = ['tools', 'attachments'];

// The physical desktop is shared by all sessions; serialize all plugin calls.
let tail = Promise.resolve();
function serialized(work) {
  const result = tail.then(work);
  tail = result.catch(() => {});
  return result;
}

export async function runBackend(action, params, { signal, python = 'python' } = {}) {
  if (process.platform !== 'win32') throw new Error('This plugin controls a Windows host desktop.');
  signal?.throwIfAborted();
  const folder = await mkdtemp(join(tmpdir(), 'dsh-computer-'));
  let out, err;
  try {
    const input = join(folder, 'params.json');
    const output = join(folder, 'result.json');
    const errors = join(folder, 'stderr.txt');
    await writeFile(input, JSON.stringify(params), 'utf8');
    out = await open(output, 'w');
    err = await open(errors, 'w');
    await new Promise((resolve, reject) => {
      const child = spawn(python, [join(root, 'computer_agent.py'), action, '--params-file', input], {
        cwd: root, windowsHide: true, shell: false,
        stdio: ['ignore', out.fd, err.fd],
        env: { ...process.env, PYTHONIOENCODING: 'utf-8' },
      });
      let interrupted = false;
      const stop = () => { interrupted = true; child.kill(); };
      const timer = setTimeout(stop, 50000);
      signal?.addEventListener('abort', stop, { once: true });
      if (signal?.aborted) stop();
      const clean = () => { clearTimeout(timer); signal?.removeEventListener('abort', stop); };
      child.once('error', error => { clean(); reject(error); });
      child.once('close', () => {
        clean();
        if (interrupted) reject(new Error('Desktop operation interrupted; its state may be unknown. Inspect before retrying.'));
        else resolve();
      });
    });
    const text = await readFile(output, 'utf8');
    let response;
    try { response = JSON.parse(text.replace(/^\uFEFF/, '')); }
    catch { throw new Error(`Desktop backend did not return JSON: ${(await readFile(errors, 'utf8')).slice(-2000)}`); }
    if (!response.ok) throw new Error(response.error);
    return response.result;
  } finally {
    await out?.close();
    await err?.close();
    await rm(folder, { recursive: true, force: true });
  }
}

export function apply(ctx, config = {}) {
  for (const spec of specs) {
    const action = spec.name;
    const description = action === 'screenshot'
      ? 'Capture the visible desktop or a window and return an image for visual inspection. Overlapping windows are included.'
      : spec.description;
    ctx.effect(() => ctx.tools.register({
      name: `computer_${action}`,
      description,
      parameters: spec.input_schema,
      timeoutMs: 120000,
      isConcurrencySafe: () => false,
      output: {
        schema: { type: 'object', additionalProperties: true },
        render(_args, value) {
          const { image, ...details } = value;
          const blocks = [{ type: 'text', text: JSON.stringify(details) }];
          if (image) blocks.push({ type: 'image', attachment: image });
          return blocks;
        },
      },
      async execute(args, exec) {
        return serialized(async () => {
          exec.signal.throwIfAborted();
          const params = { ...args };
          // A unique capture avoids overwriting screenshots from other calls/sessions.
          if (action === 'screenshot' && !params.path) params.path = join(tmpdir(), `dsh-desktop-${randomUUID()}.png`);
          const result = await runBackend(action, params, { signal: exec.signal, python: config.python || 'python' });
          if (action !== 'screenshot') return result;
          const image = await ctx.attachments.saveImage({ data: await readFile(result.path), mediaType: 'image/png', name: 'Windows desktop.png' });
          return { ...result, image };
        });
      },
    }));
  }
}
