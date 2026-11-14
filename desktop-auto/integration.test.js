import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, access, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { apply } from './index.js';
const shell = join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe');
const dir = await mkdtemp(join(tmpdir(), 'dsh-hybrid-test-'));
const ready = join(dir, 'hwnd.txt'), result = join(dir, 'result.txt');
const fixture = spawn(shell, ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', join(process.cwd(), 'fixture.ps1'), '-ReadyPath', ready, '-ResultPath', result], { windowsHide: true, stdio: 'ignore' });
const tools = new Map(), cleanup = [];
let askCount = 0;
const exec = { agent: { id: 'dedicated-test' }, callId: 'test-call', signal: new AbortController().signal };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
apply({ effect(fn) { cleanup.push(fn()); }, tools: { register(tool) { tools.set(tool.name, tool); return () => tools.delete(tool.name); } },
  attachments: { async saveImage({data}) { return { attachmentId: 'test-image', mediaType: 'image/png', bytes: data.length, width: 1, height: 1 }; } },
  userQuestions: { async ask() { askCount++; throw new Error('Automatic takeover must not ask for confirmation'); } },
});
const call = (name,args) => tools.get(name).execute(args,exec);
try {
  for (let i=0;i<100;i++) { try { await access(ready); break; } catch { await sleep(100); } }
  const hwnd = Number(await readFile(ready,'utf8'));
  assert(hwnd > 0);
  assert.equal(tools.size,9);
  const tree = await call('computer_inspect',{hwnd});
  assert(tree.controls.some(c => c.control_type === 'ControlType.Edit'));
  const selector = { control_type: 'ControlType.Edit' };
  const attempt = await call('computer_act',{hwnd,operation:'set_value',selector,value:''});
  assert(attempt.automatic_takeover);
  assert.equal(askCount,0);
  assert.equal((await call('computer_takeover',{action:'status'})).active,true);
  await assert.rejects(tools.get('computer_takeover').execute({action:'status'}, {...exec, agent:{id:'other-session'}}), /Another session owns/);
  const fresh=await call('computer_inspect',{hwnd});
  const window=fresh.controls[0].bounds;
  const edit=fresh.controls.find(c => c.control_type === 'ControlType.Edit').bounds;
  const button=fresh.controls.find(c => c.control_type === 'ControlType.Button').bounds;
  const point=b => ({x:Math.round(b.x-window.x+b.width/2),y:Math.round(b.y-window.y+b.height/2)});
  await call('computer_act',{hwnd,operation:'click',...point(edit)});
  await call('computer_act',{hwnd,operation:'type',text:'Agent control verified'});
  await call('computer_act',{hwnd,operation:'click',...point(button)});
  assert.equal(await readFile(result,'utf8'),'Agent control verified');
  await mkdir('artifacts',{recursive:true});
  const shot=await call('computer_screenshot',{hwnd,path:join(process.cwd(),'artifacts/takeover-verified.png')});
  assert.equal(shot.mode,'foreground');
  assert(shot.image);
  await call('computer_stop',{});
  assert.equal((await call('computer_takeover',{action:'status'})).active,false);
  const again=await call('computer_act',{hwnd,operation:'click',x:100,y:100});
  assert(again.automatic_takeover);
  assert.equal(askCount,0);
  await new Promise((resolve,reject)=>{
    const hotkey=spawn(shell,['-NoProfile','-File',join(process.cwd(),'test-hotkey.ps1'),'-TargetHwnd',String(hwnd)],{windowsHide:true,stdio:'ignore'});
    hotkey.once('error',reject); hotkey.once('exit',code=>code===0?resolve():reject(new Error('Hotkey test failed')));
  });
  await sleep(250);
  assert.equal((await call('computer_takeover',{action:'status'})).active,false,'Emergency hotkey must end takeover');
  await assert.rejects(call('computer_takeover',{action:'begin',ticket:'invalid'}));
  console.log(JSON.stringify({passed:true,tools:tools.size,background_attempt:true,automatic_takeover_no_prompts:true,takeover_input:true,actual_button_result:true,image_attachment:true,stop:true}));
} finally {
  await call('computer_stop',{}).catch(()=>{});
  cleanup.reverse().forEach(fn=>fn?.());
  fixture.kill();
}
