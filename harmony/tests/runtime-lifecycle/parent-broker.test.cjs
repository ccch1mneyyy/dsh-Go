const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),assert=require('node:assert/strict'),{test}=require('node:test');
const ts=require(process.argv[2]||'typescript');
const source=path.resolve(__dirname,'../../plugins/dsh_runtime_ohos/broker/parent-broker.ts');
const compiled=ts.transpileModule(fs.readFileSync(source,'utf8'),{reportDiagnostics:true,compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}});assert.equal(compiled.diagnostics.length,0);
const exported={};vm.runInNewContext(compiled.outputText,{exports:exported,Uint8Array,DataView});
const codec={encodeText:s=>new TextEncoder().encode(s),decodeText:b=>new TextDecoder('utf-8',{fatal:true}).decode(b),base64:b=>Buffer.from(b).toString('base64'),unbase64:s=>new Uint8Array(Buffer.from(s,'base64'))};
const spec={kind:'ptc-oneshot',argv:['/node','--max-old-space-size=512','/process.js','65536'],cwd:'/fixed',envSet:{},envUnset:['REMOVE'],stdio:{stdin:'ignore',stdout:'pipe',stderr:'pipe',control:'pipe'},graceMs:3000};
function frame(type,id=1,fields={}){const body=Buffer.from(JSON.stringify({v:1,generation:'fixed',id,type,...fields}));const value=Buffer.alloc(4+body.length);value.writeUInt32BE(body.length);body.copy(value,4);return value;}
function task(){
 const state={stops:0,reaps:0,writes:[],ended:0,closed:false,facts:null,reapPromise:Promise.resolve(),data:{stdout:[],stderr:[],control:[]},short:2};
 return Object.assign(state,{read(name,max){const bytes=this.data[name][0];if(bytes&&max){const part=bytes.slice(0,max);if(part.length===bytes.length)this.data[name].shift();else this.data[name][0]=bytes.slice(max);return {data:part,eof:false}}return {data:new Uint8Array(),eof:this.closed&&!this.data[name].length}},writeControl(bytes){const n=Math.min(bytes.length,this.short);this.writes.push(...bytes.slice(0,n));return n},endControl(){this.ended++},stop(){this.stops++},pollExit(){return this.facts},reap(){this.reaps++;return this.reapPromise}});
}
function harness(driver){let wire=Buffer.alloc(0);const messages=[];const broker=new exported.ParentBroker('fixed',driver,b=>{const n=Math.min(13,b.length);wire=Buffer.concat([wire,Buffer.from(b.slice(0,n))]);while(wire.length>=4&&wire.length>=wire.readUInt32BE(0)+4){const n=wire.readUInt32BE(0);messages.push(JSON.parse(wire.subarray(4,n+4)));wire=wire.subarray(n+4)}return n},s=>s.cwd==='/fixed',codec);return {broker,messages,async pump(){for(let i=0;i<100;i++){broker.pump();await Promise.resolve()}},send(type,id,fields){const bytes=frame(type,id,fields);broker.accept(bytes.slice(0,2));broker.accept(bytes.slice(2))}};}
test('真实状态机分帧、credit、短写完整ACK、exit之后等reap',async()=>{
 const t=task();let finish; t.reapPromise=new Promise(r=>finish=r);const h=harness({start:async()=>t});h.send('spawn');await h.pump();
 // spawn必须带完整spec。
 assert(h.broker.failure);
 const g=harness({start:async()=>t});g.send('spawn',1,{spec});await g.pump();assert.equal(g.messages[0].type,'spawned');
 t.data.stdout.push(Uint8Array.from([1,2,3]));await g.pump();assert(!g.messages.some(x=>x.type==='data'));
 g.send('readCredit',1,{stream:'stdout',bytes:2});await g.pump();assert.equal(Buffer.from(g.messages.find(x=>x.type==='data').data,'base64').length,2);
 g.send('write',1,{seq:1,data:Buffer.from([4,5,6,7,8]).toString('base64')});g.send('end',1);g.broker.pump();assert(!g.messages.some(x=>x.type==='writeAck'));await g.pump();assert.deepEqual(t.writes,[4,5,6,7,8]);assert.equal(t.ended,1);assert(g.messages.some(x=>x.type==='writeAck'));
 t.closed=true;t.facts={exitCode:0,signal:null};await g.pump();assert(!g.messages.some(x=>x.type==='exit'));
 g.send('readCredit',1,{stream:'stdout',bytes:1});await g.pump();assert(g.messages.some(x=>x.type==='exit'));assert(!g.messages.some(x=>x.type==='reaped'));
 finish();await g.pump();assert(g.messages.some(x=>x.type==='reaped'));await g.broker.settled();
});
test('stop早于异步start，迟到task收到停止',async()=>{
 const t=task();let start,token;const h=harness({start:(_s,s)=>{token=s;return new Promise(r=>start=r)}});h.send('spawn',1,{spec});await h.pump();h.send('stop');assert(token.aborted);start(t);await h.pump();assert.equal(t.stops,1);
 h.broker.disconnect();await h.broker.settled();assert.equal(t.reaps,1);
});
test('断连后迟到task必须回收且不发spawned',async()=>{
 const t=task();let start;const h=harness({start:()=>new Promise(r=>start=r)});h.send('spawn',1,{spec});await h.pump();h.broker.disconnect();start(t);await h.broker.settled();assert.equal(t.stops,1);assert.equal(t.reaps,1);assert.equal(h.messages.length,0);
});
test('start明确失败可报无遗留，reap失败不能发reaped',async()=>{
 const h=harness({start:async()=>({startFailed:true,reaped:true,code:'TASK_START_FAILED'})});h.send('spawn',1,{spec});await h.pump();assert.equal(h.messages[0].code,'TASK_START_FAILED');assert.equal(h.messages[0].reaped,true);assert(!JSON.stringify(h.messages).includes('private'));
 const t=task();t.closed=true;t.facts={exitCode:0,signal:null};t.reapPromise=Promise.reject(Error('fixed'));t.reapPromise.catch(()=>{});
 const g=harness({start:async()=>t});g.send('spawn',1,{spec});await g.pump();assert(!g.messages.some(x=>x.type==='reaped'));await assert.rejects(g.broker.settled(),/CLEANUP/);
});
test('旧代、过量credit、非法signal、超帧拒绝并回收',async()=>{
 for(const mode of ['generation','credit','signal','frame']){
  const t=task();const h=harness({start:async()=>t});h.send('spawn',1,{spec});await h.pump();
  if(mode==='generation')h.send('stop',1,{generation:'old'});
  if(mode==='credit')h.send('readCredit',1,{stream:'stdout',bytes:65537});
  if(mode==='signal'){t.closed=true;t.facts={exitCode:null,signal:'UNKNOWN'};await h.pump();}
  if(mode==='frame'){const b=Buffer.alloc(4);b.writeUInt32BE(1048577);h.broker.accept(b);}
  assert(h.broker.failure);await h.broker.settled();assert.equal(t.reaps,1);
 }
});

test('普通start拒绝不伪造reaped，保持清理未知',async()=>{
 const h=harness({start:async()=>{throw Error('private')}});h.send('spawn',1,{spec});await h.pump();assert.equal(h.messages.length,0);assert(h.broker.failure);await assert.rejects(h.broker.settled(),/CLEANUP/);
});

test('两端真实源码联调：70KB短写ACK、64KB背压、EOF与reap分离',async()=>{
 const {Duplex}=require('node:stream');const {pathToFileURL}=require('node:url');
 const {createOhosSubprocessProvider}=await import(pathToFileURL(path.resolve(__dirname,'../../plugins/dsh_runtime_ohos/assets/subprocess-ohos.mjs')).href);
 const native=task();native.short=4096;let release;native.reapPromise=new Promise(r=>release=r);
 let parent;const transport=new Duplex({read(){},write(chunk,_encoding,callback){parent.accept(new Uint8Array(chunk));callback()}});
 parent=new exported.ParentBroker('fixed',{start:async()=>native},bytes=>{const n=Math.min(bytes.length,997);transport.push(Buffer.from(bytes.slice(0,n)));return n},s=>s.cwd==='/fixed',codec);
 class Base {constructor(ctx){this.ctx=ctx}}
 const Provider=createOhosSubprocessProvider(Base,{transport,generation:'fixed',executable:'/node',bootstrapPath:'/process.js',allowCwd:cwd=>cwd==='/fixed'});
 const provider=new Provider({effect(){}});
 const handle=provider.spawn({argv:spec.argv,cwd:spec.cwd,env:{REMOVE:undefined},stdio:spec.stdio,graceMs:spec.graceMs});
 const pump=async(predicate)=>{for(let i=0;i<2000;i++){parent.pump();await new Promise(r=>setImmediate(r));if(predicate())return;}throw Error('联调等待超时')};
 try {
  await pump(()=>parent.states.get(1)?.task!==undefined);
  const payload=Buffer.alloc(70000,37);let acknowledged=false;handle.control.write(payload,()=>acknowledged=true);
  parent.pump();assert.equal(acknowledged,false);await pump(()=>acknowledged);
  assert.equal(native.writes.length,70000);assert(native.writes.every(x=>x===37));
  native.data.stdout.push(Buffer.alloc(70000,65));await pump(()=>handle.stdout.readableLength===65536);
  assert.equal(native.data.stdout[0].length,4464);
  for(let i=0;i<20;i++)parent.pump();assert.equal(native.data.stdout[0].length,4464);
  assert.equal(handle.stdout.read(65536).length,65536);await pump(()=>handle.stdout.readableLength===4464);
  assert.equal(handle.stdout.read(4464).length,4464);
  native.closed=true;native.facts={exitCode:0,signal:null};let done=false;let reaped=false;
  handle.done.then(()=>done=true);handle.waitForExit().then(()=>reaped=true);
  await pump(()=>done);assert.equal(reaped,false);assert.equal(native.reaps,1);
  release();await pump(()=>reaped);await parent.settled();assert.deepEqual(await handle.done,{exitCode:0,signal:null});
 }finally{provider.fail('TEST_END');parent.disconnect();await parent.settled();}
});
