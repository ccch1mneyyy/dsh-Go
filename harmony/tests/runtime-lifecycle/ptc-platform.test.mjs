import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { isAbsolute } from 'node:path';
import { patchOhosPtc } from '../../plugins/dsh_runtime_ohos/scripts/patch-ptc-runtime.mjs';
const input=process.argv[2];if(!input)throw Error('请传入固定原版rc4 index.js路径');
const source=readFileSync(input), original=source.toString(), patched=patchOhosPtc(source);
function harness(){
 const classStart=patched.indexOf('var OhosIsolatedPtcRuntime = class');
 const classCode=patched.slice(classStart,patched.indexOf('//#endregion',classStart));
 const policyStart=patched.indexOf('var PolicyProcesses = class');
 const policyCode=patched.slice(policyStart,patched.indexOf('//#endregion',policyStart));
 const events=[],effects=[];const policy={mode:'workspace-write',workspaceRoot:'/private/fixed',sessionId:'fixed'};
 const ctx={subprocess:{ohosIsolatedPtc:true},sandboxPolicy:{defaultMode:policy.mode,resolve:()=>policy},get:()=>undefined,on:(...args)=>events.push(args),effect:(fn)=>effects.push(fn),logger:{warn(){}}};
 const sandbox={PtcRuntime:class{constructor(ctx){this.ctx=ctx}release(){return Promise.resolve()}},NodeConfig:{},resolveLaunch:x=>x,validateConfig(){},isAbsolute,clampTimeout:(_v,d)=>d,AbortController,AbortSignal,Promise,validateBindings:spec=>new Map(spec.bindings.map(x=>[x.global,x]))};
 vm.createContext(sandbox);vm.runInContext(policyCode+'\n'+classCode+'\nglobalThis.Provider=OhosIsolatedPtcRuntime;',sandbox);
 const config={executionMode:'per-call',launch:{kind:'node-script',executable:'/ohos/node'},timeoutMs:1000,maxTimeoutMs:5000};
 return {Provider:sandbox.Provider,ctx,config,policy,events,effects,sandbox};
}

test('正式run不包含临时钩子并保持返回对象同一引用',async()=>{
 const h=harness(),runtime=new h.Provider(h.ctx,h.config);
 const result={logs:[],error:{kind:'exception',message:'不得传给钩子的正文'}};
 runtime.execute=async()=>result;
 const spec=runtime.resolve({program:'fixed',bindings:[]});
 assert.equal(await runtime.run(spec),result);
 let received;
 h.sandbox.__dshPtcProbeKind=(...args)=>{received=args;throw Error('固定观察器失败');};
 assert.equal(await runtime.run(spec),result);
 assert.equal(received,undefined);assert.equal(patched.includes('__dshPtcProbeKind'),false);
 runtime.execute=async()=>({logs:[],value:42});
 await runtime.run(spec);assert.equal(received,undefined);
});
test('固定源摘要拒绝任何漂移，原绑定/权限生命周期源码不变',()=>{
 assert.throws(()=>patchOhosPtc(Buffer.concat([source,Buffer.from('\n')])),/HASH/);
 const begin=original.indexOf('var NodePtcRuntime = class');
 assert.equal(patched.slice(0,begin),original.slice(0,begin));
 const binding=s=>s.slice(s.indexOf('\t\t\t\t\tcase "call":',s.indexOf('async execute(spec')),s.indexOf('\t\t\t\t\tdefault: protocolFailure',s.indexOf('async execute(spec')));
 assert(binding(original).length>1000);assert.equal(binding(patched),binding(original));
 assert(!patched.slice(begin).includes('this.ctx.sandbox.confine('));
 assert(patched.includes('cwd: spec.workerCwd'));assert(patched.includes('enforcement: "partial"'));
 assert(!patched.includes('policy.mode = "danger-full-access"'));
});
test('真实provider构造拒绝persistent/embedded/无隔离装配标记',()=>{
 const h=harness();assert.throws(()=>new h.Provider(h.ctx,{...h.config,executionMode:'persistent-in-memory'}),/PERSISTENT/);
 assert.throws(()=>new h.Provider(h.ctx,{...h.config,launch:{kind:'embedded'}}),/LAUNCH/);
 assert.throws(()=>new h.Provider({...h.ctx,subprocess:{}},h.config),/ISOLATION/);
});
test('真实resolve保留cwd与策略引用并显式增加worker范围，run拒绝未解析输入',async()=>{
 const h=harness(),runtime=new h.Provider(h.ctx,h.config);const bindings=[{global:'tools',functions:{fixed:()=>42}}];
 const spec=runtime.resolve({program:'return 42',bindings,cwd:'/private/other',sandboxPolicy:h.policy});
 assert.equal(spec.cwd,'/private/other');assert.equal(spec.sandboxPolicy,h.policy);assert.equal(spec.bindings,bindings);assert.equal(spec.workerCwd,'/');assert.equal(spec.executionScope,'isolated-bindings');
 assert.match(runtime.executionInstructions,/真实 process.cwd\(\) 固定为/);assert.match(runtime.executionInstructions,/partial/);
 await assert.rejects(runtime.run({...spec,workerCwd:'/private/other'}),/UNRESOLVED/);
 assert.equal(runtime.resolve({program:'',bindings}).cwd,h.policy.workspaceRoot);
});
test('原PolicyProcesses真实mode撤销会取消当前run并等待完成',async()=>{
 const h=harness(),runtime=new h.Provider(h.ctx,h.config);let started,finished=false;const ready=new Promise(r=>started=r);
 runtime.execute=async(spec,policy,bindings,controller)=>{assert.equal(policy,h.policy);assert.equal(spec.cwd,'/private/fixed');assert.equal(bindings.get('tools').functions.fixed(),42);started();await new Promise(r=>controller.signal.addEventListener('abort',r,{once:true}));finished=true;return {logs:[],error:{kind:'abort',message:'fixed'}}};
 const run=runtime.run(runtime.resolve({program:'fixed',bindings:[{global:'tools',functions:{fixed:()=>42}}]}));await ready;
 const listener=h.events.find(x=>x[0]==='session/event')[1];listener({id:'fixed'},{type:'sandbox/mode',data:{mode:'read-only'}});
 assert.equal((await run).error.kind,'abort');assert(finished);assert.equal(runtime.live.size,0);
});
