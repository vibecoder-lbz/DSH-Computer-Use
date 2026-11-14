import test from 'node:test';
import assert from 'node:assert/strict';
import { apply } from './index.js';

const tools = new Map();
const disposers = [];
apply({
  effect(fn) { disposers.push(fn()); },
  tools: { register(def) { assert(!tools.has(def.name)); tools.set(def.name, def); return () => tools.delete(def.name); } },
  attachments: { async saveImage({ data, mediaType }) {
    assert.equal(data.subarray(1, 4).toString(), 'PNG');
    return { attachmentId: 'test-ref', mediaType, bytes: data.length, width: 1, height: 1 };
  } },
});
const exec = { signal: new AbortController().signal };
test('registers eleven distinct tools with cleanup', () => {
  assert.equal(tools.size, 11);
  for (const tool of tools.values()) {
    assert.equal(tool.isConcurrencySafe(), false);
    assert.equal(tool.parameters.additionalProperties, false);
  }
  const bytes = JSON.stringify([...tools.values()].map(({name, description, parameters}) => ({name, description, parameters}))).length;
  console.log(`Model tool schema characters: before=0, after=${bytes}; estimate=${Math.ceil(bytes / 4)} tokens (tokenizer dependent).`);
});
test('Windows software listing through plugin executor', async () => {
  const value = await tools.get('computer_apps').execute({ limit: 2 }, exec);
  assert(value.total >= value.apps.length);
  assert(value.apps.length <= 2);
});
test('desktop windows and inspection through plugin executor', async () => {
  const value = await tools.get('computer_windows').execute({}, exec);
  assert(Array.isArray(value.windows));
  if (value.windows.length) {
    const tree = await tools.get('computer_inspect').execute({ hwnd: value.windows[0].hwnd, limit: 5, depth: 1 }, exec);
    assert(tree.controls.length > 0);
  }
});
test('screenshots render as durable image blocks', async () => {
  const tool = tools.get('computer_screenshot');
  const value = await tool.execute({}, exec);
  const content = tool.output.render({}, value);
  assert.equal(content[1].type, 'image');
  assert.equal(content[1].attachment.attachmentId, 'test-ref');
  assert(value.width > 0);
});
test('invalid input and aborted calls do not execute', async () => {
  await assert.rejects(tools.get('computer_click').execute({ hwnd: 1, x: -1, y: 0 }, exec));
  const controller = new AbortController(); controller.abort();
  await assert.rejects(tools.get('computer_windows').execute({}, { signal: controller.signal }));
});
test('unload unregisters every tool', () => {
  disposers.reverse().forEach(dispose => dispose());
  assert.equal(tools.size, 0);
});
