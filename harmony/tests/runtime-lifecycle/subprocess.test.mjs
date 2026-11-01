import { test } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import path from 'node:path';
let socketId=0;
import { once } from 'node:events';
import { createOhosSubprocessProvider } from '../../plugins/dsh_runtime_ohos/assets/subprocess-ohos.mjs';
const pause=()=>new Promise(resolve=>setTimeout(resolve,10));
async function harness(){
 const server=net.createServer();const socketPath=process.env.DSH_TEST_UNIX==='1'?'\0dsh-broker-'+process.pid+'-'+(++socketId):process.env.DSH_TEST_SOCKET_DIR?path.join(process.env.DSH_TEST_SOCKET_DIR,'broker-'+process.pid+'-'+(++socketId)+'.sock'):null;
 if(socketPath)server.listen(socketPath);else server.listen(0,'127.0.0.1');await once(server,'listening');
 const accepted=once(server,'connection');const transport=socketPath?net.connect(socketPath):net.connect(server.address().port,'127.0.0.1');
 const [peer]=await accepted;await once(transport,'connect');
 let input=Buffer.alloc(0);const messages=[];
 peer.on('data',chunk=>{input=Buffer.concat([input,chunk]);while(input.length>=4&&input.length>=input.readUInt32BE(0)+4){const n=input.readUInt32BE(0);messages.push(JSON.parse(input.subarray(4,n+4)));input=input.subarray(n+4);}});
 class Base {constructor(ctx){this.ctx=ctx}}
 const Runtime=createOhosSubprocessProvider(Base,{transport,generation:'test-generation',executable:'/fixed/node',bootstrapPath:'/fixed/process.js',allowCwd:cwd=>cwd==='/fixed/workspace'});
 const runtime=new Runtime({effect(){}});
 const send=(type,id=1,fields={})=>{const body=Buffer.from(JSON.stringify({v:1,generation:'test-generation',id,type,...fields}));const wire=Buffer.alloc(body.length+4);wire.writeUInt32BE(body.length);body.copy(wire,4);peer.write(wire.subarray(0,3));peer.write(wire.subarray(3));};
 const wait=async predicate=>{for(let i=0;i<100;i++){if(predicate())return;await pause()}throw Error('固定测试等待超时')};
 const spec={argv:['/fixed/node','--max-old-space-size=512','/fixed/process.js','134217728'],cwd:'/fixed/workspace',env:{REMOVE_ME:undefined,FIXED:'test'},stdio:{stdin:'ignore',stdout:'pipe',stderr:'pipe',control:'pipe'},graceMs:3000};
 const finish=(id=1,code=0)=>{for(const stream of ['stdout','stderr','control'])send('eof',id,{stream});send('exit',id,{exitCode:code,signal:null});};
 const close=()=>{runtime.fail('TEST_END');peer.destroy();server.close();};
 return {runtime,peer,messages,send,wait,spec,finish,close};
}
test('同步handle、显式env删除、分片帧、ack后写完成、退出与回收分离',async()=>{
 const h=await harness();try{
  const handle=h.runtime.spawn(h.spec);assert(handle.control);await h.wait(()=>h.messages.length===1);
  assert.deepEqual(h.messages[0].spec.envUnset,['REMOVE_ME']);assert.deepEqual(h.messages[0].spec.envSet,{FIXED:'test'});
  h.send('spawned');await h.wait(()=>h.messages.filter(m=>m.type==='readCredit').length===3);
  let wrote=false;handle.control.write(Buffer.alloc(70000,42),()=>wrote=true);
  await h.wait(()=>h.messages.some(m=>m.type==='write'));assert.equal(wrote,false);
  let write=h.messages.find(m=>m.type==='write');assert.equal(Buffer.from(write.data,'base64').length,65536);h.send('writeAck',1,{seq:write.seq});
  await h.wait(()=>h.messages.filter(m=>m.type==='write').length===2);write=h.messages.filter(m=>m.type==='write')[1];h.send('writeAck',1,{seq:write.seq});await h.wait(()=>wrote);
  h.finish();assert.deepEqual(await handle.done,{exitCode:0,signal:null});
  let reaped=false;handle.waitForExit().then(()=>reaped=true);await pause();assert.equal(reaped,false);h.send('reaped');await handle.waitForExit();
 }finally{h.close()}
});
test('读取credit限制缓冲，消费后才补额度',async()=>{
 const h=await harness();try{
  const handle=h.runtime.spawn(h.spec);h.send('spawned');await h.wait(()=>h.messages.length>=4);
  h.send('data',1,{stream:'stdout',data:Buffer.alloc(65536,65).toString('base64')});await h.wait(()=>handle.stdout.readableLength===65536);
  assert.equal(h.messages.filter(m=>m.type==='readCredit'&&m.stream==='stdout').length,1);
  assert.equal(handle.stdout.read(65536).length,65536);
  await h.wait(()=>h.messages.filter(m=>m.type==='readCredit'&&m.stream==='stdout').length===2);
  h.finish();h.send('reaped');await handle.waitForExit();
 }finally{h.close()}
});

test('半个窗口未消费时不提前补额度',async()=>{
 const h=await harness();try{
  const handle=h.runtime.spawn(h.spec);h.send('spawned');await h.wait(()=>h.messages.length>=4);
  handle.stdout.read(0);
  h.send('data',1,{stream:'stdout',data:Buffer.alloc(32768,65).toString('base64')});
  await h.wait(()=>handle.stdout.readableLength===32768);await pause();
  assert.equal(h.messages.filter(m=>m.type==='readCredit'&&m.stream==='stdout').length,1);
  h.finish();h.send('reaped');await handle.waitForExit();
 }finally{h.close()}
});
test('取消先于spawned仍回收迟到任务，并行任务ID独立',async()=>{
 const h=await harness();try{
  const abort=new AbortController();const a=h.runtime.spawn({...h.spec,signal:abort.signal});const b=h.runtime.spawn(h.spec);abort.abort();
  await h.wait(()=>h.messages.some(m=>m.type==='stop'&&m.id===1));h.send('spawned',1);h.send('spawned',2);
  await h.wait(()=>h.messages.filter(m=>m.type==='stop'&&m.id===1).length===2);
  h.finish(1,1);h.send('reaped',1);h.finish(2,0);h.send('reaped',2);
  assert.equal((await a.done).exitCode,1);assert.equal((await b.done).exitCode,0);await Promise.all([a.waitForExit(),b.waitForExit()]);
 }finally{h.close()}
});
test('不支持shell/cwd，spawnError明确无遗留，连接中断拒绝回收',async()=>{
 const h=await harness();try{
  assert.throws(()=>h.runtime.spawn({...h.spec,argv:['sh','-c','echo wrong']}),/UNSUPPORTED/);
  assert.throws(()=>h.runtime.spawn({...h.spec,cwd:'/elsewhere'}),/UNSUPPORTED/);
  const a=h.runtime.spawn(h.spec);h.send('spawnError',1,{code:'FIXED_START_FAILED',reaped:true});await assert.rejects(a.done,/FIXED_START_FAILED/);await a.waitForExit();
  const b=h.runtime.spawn(h.spec);h.peer.destroy();await assert.rejects(b.done,/DISCONNECTED/);await assert.rejects(b.waitForExit(),/DISCONNECTED/);
 }finally{h.close()}
});
for(const scenario of ['generation','credit','exit','signal'])test('非法父消息拒绝：'+scenario,async()=>{
 const h=await harness();try{const a=h.runtime.spawn(h.spec);h.send('spawned');await h.wait(()=>h.messages.length>=4);
 if(scenario==='generation')h.send('eof',1,{generation:'old',stream:'stdout'});
 if(scenario==='credit')h.send('data',1,{stream:'stdout',data:Buffer.alloc(65537).toString('base64')});
 if(scenario==='exit')h.send('exit',1,{exitCode:0,signal:null});
 if(scenario==='signal'){for(const stream of ['stdout','stderr','control'])h.send('eof',1,{stream});h.send('exit',1,{exitCode:null,signal:'UNKNOWN'});}
 await assert.rejects(a.done,/PROTOCOL/);await assert.rejects(a.waitForExit(),/PROTOCOL/);
 }finally{h.close()}
});

test('1MiB帧上限和未知ACK失败，不把销毁当回收',async()=>{
 for(const huge of [true,false]){const h=await harness();try{
 const a=h.runtime.spawn(h.spec);h.send('spawned');await h.wait(()=>h.messages.length>=4);
 if(huge){const header=Buffer.alloc(4);header.writeUInt32BE(1048577);h.peer.write(header);}else h.send('writeAck',1,{seq:42});
 await assert.rejects(a.done,/PROTOCOL/);await assert.rejects(a.waitForExit(),/PROTOCOL/);
 }finally{h.close()}}
});
test('dispose等真实reaped后才关闭连接',async()=>{
 const h=await harness();try{
 const a=h.runtime.spawn(h.spec);h.send('spawned');await h.wait(()=>h.messages.length>=4);
 let disposed=false;const disposing=h.runtime.dispose().then(()=>disposed=true);
 await h.wait(()=>h.messages.some(m=>m.type==='stop'));h.finish();await a.done;await pause();assert.equal(disposed,false);
 h.send('reaped');await disposing;assert.equal(disposed,true);
 }finally{h.close()}
});

test('平台能力标记只读，不替代原生隔离验收', async()=>{const h=await harness();try{assert.equal(h.runtime.ohosIsolatedPtc,true);assert.throws(()=>{h.runtime.ohosIsolatedPtc=false},TypeError);assert.equal(h.runtime.ohosIsolatedPtc,true)}finally{h.close()}});
