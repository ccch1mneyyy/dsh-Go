const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),assert=require('node:assert/strict');
const ts=require(process.argv[2]||'typescript');
const root=path.resolve(__dirname,'../../..');
function load(file, extras={}) {
 const exports={};
 const code=ts.transpileModule(fs.readFileSync(path.join(root,file),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
 vm.runInNewContext(code,{exports,require:()=>({hilog:{info(){},error(){}}}),setTimeout,clearTimeout,...extras});
 return new exports.default();
}
function harness(stopFailure=false, options={}) {
 const files=new Map();let starts=0,stops=0,now=0,stopAt=-1;
 const endpoint='/test/engine-endpoint.json';
 const api={accessSync:p=>files.has(p)||p==='/proc/7',readTextSync:p=>{if(!files.has(p))throw Error();return files.get(p)},unlinkSync:p=>files.delete(p),mkdirSync:p=>files.set(p,'')};
 const ui={abilityInfo:{bundleName:'fixture.changed.bundle'},startAbility:async want=>{assert.equal(want.bundleName,'fixture.changed.bundle');if(want.parameters.action==='stop'){stops++;stopAt=now;files.set(endpoint,JSON.stringify(stopFailure?{error:'stop_failed'}:options.stopDelay?{error:'spawn_pending'}:{stopped:true}));}else{starts++;assert.equal(want.parameters.enablePrivateBroker,true);assert.equal(want.parameters.runRealToolsProbe,undefined);if(!options.neverReady)files.set(endpoint,JSON.stringify({baseUrl:'http://127.0.0.1:38081/',token:'test-only',pid:7,workspaceDir:want.parameters.dataRoot+'/workspace'}));}}};
 const p=load('app/ohos/entry/src/main/ets/plugins/DshRuntimePlugin.ets',{Date:{now:()=>now},require:name=>name==='@kit.CoreFileKit'?{fileIo:api}:{hilog:{info(){},error(){}}},AppStorage:{get:()=>ui}});
 p.context={filesDir:'/test'};p.engineDir='/test/install';p.hasEngine=()=>true;p.needsReinstall=()=>false;p.sleep=ms=>new Promise(r=>setImmediate(()=>{now+=ms;if(options.stopDelay&&stopAt>=0&&now-stopAt>=options.stopDelay)files.set(endpoint,JSON.stringify({stopped:true}));r();}));
 const invoke=(method,args={})=>new Promise(resolve=>p.onMethodCall({method,argument:key=>args[key]},{success:()=>resolve('ok'),error:code=>resolve(code)}));
 return {p,files,endpoint,invoke,starts:()=>starts,stops:()=>stops,now:()=>now};
}
function hostHarness() {
 let now=0, nextPid=20, pendingResolve, pendingReject;
 const exited=new Set(), kills=[], writes=[], logs=[], callbacks=[], brokerEvents=[], cleared=[];
 const state={delayed:false,stopCode:0,confirm:true,report:null,privateBroker:false,brokerFail:false,existingRoot:null};
 const ability=load('app/ohos/entry/src/main/ets/engineability/EngineAbility.ets',{
  Date:{now:()=>now},setTimeout:fn=>{now+=50;queueMicrotask(fn);return 1},
  setInterval:fn=>{callbacks.push(fn);return callbacks.length},clearInterval:id=>cleared.push(id),
  require:name=>name==='@kit.AbilityKit'?{UIAbility:class{}}:
   name==='libdsh_broker.so'?{default:{create(){brokerEvents.push('create');return {handle:1,fd:60,error:0}},attached(h){brokerEvents.push('attached');return 0},close(){brokerEvents.push('close');return 0}}}:
   name==='./HarmonyBrokerHost'?{HarmonyBrokerHost:class{start(){brokerEvents.push('host-start')}async shutdown(){brokerEvents.push('shutdown');if(state.brokerFail)throw Error('fixed');brokerEvents.push('closed')}}}:
   name==='./HarmonyTaskDriver'?{HarmonyTaskDriver:class{accepts(){return true}}}:

   name==='libdsh_control.so'?{default:{forget:pid=>exited.delete(pid),watch:()=>0,reset:()=>exited.clear(),exited:pid=>exited.has(pid),stop:pid=>{kills.push(pid);if(state.confirm&&state.stopCode===0)exited.add(pid);return state.stopCode}}}:
   name==='@ohos.app.ability.childProcessManager'?{default:{startNativeChildProcess:(_entry,args)=>{if(state.privateBroker){assert.match(args.entryParams,/^dsh\|\/installed\|(\/data|\/test\/engine-tools-probe-[0-9]+)\|engine-/);assert.equal(args.fds.dshBroker,60)}else{assert.equal(args.entryParams,'dsh|/installed|/data');assert.equal(args.fds,undefined)}return state.delayed?new Promise((resolve,reject)=>{pendingResolve=resolve;pendingReject=reject}):Promise.resolve(nextPid++)}}}:
   name==='@kit.CoreFileKit'?{fileIo:{accessSync:p=>p===state.existingRoot||state.report!==null,readTextSync:()=>JSON.stringify(state.report),unlinkSync(){},mkdirSync(){}}}:
   {hilog:{info:(...args)=>logs.push(args.join(' ')),error:(...args)=>logs.push(args.join(' '))}},
 });
 ability.context={filesDir:'/test'};
 ability.writeEndpoint=(_p,value)=>writes.push(JSON.parse(value));
 const want={parameters:{installedRoot:'/installed',endpointFile:'/endpoint',dataRoot:'/data'}};
 return {ability,state,kills,writes,logs,callbacks,brokerEvents,cleared,start:()=>ability.handleWant({...want,parameters:{...want.parameters,enablePrivateBroker:state.privateBroker}}),resolve:pid=>pendingResolve(pid),reject:error=>pendingReject(error)};
}
const flush=async()=>{for(let i=0;i<8;i++)await Promise.resolve()};
(async()=>{
 // 真实主桥方法分派：拒绝未实现操作，不启动/停止、不改写任何资料或端点。
 const unsupported=['reset','setAutoSafe','setDirectEngine','restoreLastKnownGood','safePreflight','moveAside','requestBatteryExempt','openBackgroundSettings','openVendorSettings','openAllFilesAccess'];
 for(const method of unsupported){const rejected=harness();rejected.files.set('/test/engine-data/fixture','preserve');rejected.files.set(rejected.endpoint,'preserve-endpoint');const before=[...rejected.files];assert.equal(await rejected.invoke(method,{enabled:true,keep:['uiAndSkills'],paths:['fixture']}),'UNSUPPORTED',method);assert.equal(rejected.starts(),0);assert.equal(rejected.stops(),0);assert.deepEqual([...rejected.files],before);assert.equal(rejected.p.phase,'notInstalled');}
 const safe=harness();assert.equal(await safe.invoke('start',{mode:'safe'}),'UNSUPPORTED');assert.equal(safe.starts(),0);assert.equal(safe.stops(),0);assert.equal(safe.files.size,0);assert.equal(await safe.invoke('start',{mode:'normal'}),'ok');assert.equal(safe.starts(),1);assert.equal(await safe.invoke('start',{mode:'safe'}),'UNSUPPORTED');assert.equal(safe.starts(),1);assert.equal(safe.p.phase,'running');
 const lkg=harness();let available;lkg.p.onMethodCall({method:'lastKnownGood'},{success:value=>{available=value.get('available');}});assert.equal(available,false);assert.equal(lkg.starts(),0);
 let h=harness();assert.deepEqual(await Promise.all([h.invoke('start'),h.invoke('start')]),['ok','ok']);assert.equal(h.starts(),1);assert.equal(h.p.workspaceDir,'/test/engine-data/workspace');
 assert.equal(await h.invoke('stop'),'ok');assert.equal(h.stops(),1);assert.equal(h.p.phase,'installed');assert.equal(h.files.has(h.endpoint),false);
 await h.invoke('start');assert.equal(h.p.workspaceDir,'/test/engine-data/workspace');assert.equal(h.starts(),2);
 h.files.set(h.endpoint,JSON.stringify({error:'engine_exited'}));h.p.refreshRunning();assert.equal(h.p.phase,'error');assert.equal(h.p.token,null);
 h=harness(true);await h.invoke('start');assert.equal(await h.invoke('stop'),'STOP_FAILED');assert.equal(h.p.phase,'error');
 h=harness();const start=h.invoke('start');const stop=h.invoke('stop');await Promise.all([start,stop]);assert.equal(h.p.phase,'installed');assert.equal(h.stops(),1);
 // 启动期限到达后先发停止，spawn_pending不是退出确认。
 h=harness(false,{neverReady:true,stopDelay:12000});
 assert.equal(await h.invoke('start'),'START_FAILED');assert.equal(h.stops(),1);assert(h.now()>=102000);assert.equal(h.p.childPid,-1);assert.equal(h.p.token,null);assert.equal(h.p.error,'start failed: engine_start_timeout');
 h=harness(false,{stopDelay:35000});await h.invoke('start');assert.equal(await h.invoke('stop'),'ok');assert(h.now()>=35000);assert.equal(h.p.phase,'installed');
 h=harness(true,{neverReady:true});assert.equal(await h.invoke('start'),'START_FAILED');assert.equal(h.stops(),1);assert.equal(h.p.error,'start failed: stop_failed');
 h=harness(false,{neverReady:true,stopDelay:50000});assert.equal(await h.invoke('start'),'START_FAILED');assert.equal(h.stops(),1);assert.equal(h.p.error,'start failed: stop_confirmation_timeout');assert(h.now()>=135000);assert.notEqual(h.files.get(h.endpoint),JSON.stringify({stopped:true}));
 let tick, exited=false, spawned=0, killed=0;
 const writes=[];
 const ability=load('app/ohos/entry/src/main/ets/engineability/EngineAbility.ets',{
  require:name=> name==='@kit.AbilityKit'?{UIAbility:class{}}: name==='libdsh_control.so'?{default:{forget:()=>{exited=false;return 1},watch:()=>0,reset:()=>{exited=false},exited:()=>exited?1:0,stop:()=>{killed++;exited=true;return 0}}}:name==='@ohos.app.ability.childProcessManager'?{default:{startNativeChildProcess:async (_entry,args)=>{spawned++;assert.equal(args.entryParams,'dsh|/installed|/data');return 9}}}:name==='@kit.CoreFileKit'?{fileIo:{accessSync:()=>false,mkdirSync(){}}}:{hilog:{info(){},error(){}}},
  setInterval:fn=>{tick=fn;return 1},clearInterval:()=>{},
 });
 ability.context={filesDir:'/test'};
 ability.writeEndpoint=(_p,value)=>writes.push(JSON.parse(value));
 const want={parameters:{installedRoot:'/installed',endpointFile:'/endpoint',dataRoot:'/data'}};
 ability.handleWant(want);ability.handleWant(want);await Promise.resolve();await Promise.resolve();assert.equal(spawned,1);
 exited=true;tick();await flush();assert.equal(writes.at(-1).error,'engine_exited');
 ability.handleWant(want);await Promise.resolve();await Promise.resolve();assert.equal(spawned,2);
 await ability.stop('/endpoint');assert.equal(killed,1);assert.equal(writes.at(-1).stopped,true);
 const engineText=fs.readFileSync(path.join(root,'app/ohos/entry/src/main/ets/engineability/EngineAbility.ets'),'utf8');assert(!engineText.includes('runBrokerProbe'));assert(!engineText.includes('BrokerProbeRunner'));
 const readyHost=hostHarness();readyHost.state.privateBroker=true;readyHost.start();await flush();readyHost.state.report={base_url:'http://127.0.0.1:38081/',access_token:'test-only'};readyHost.callbacks[0]();await flush();assert.equal(readyHost.writes.at(-1).workspaceDir,'/data/workspace');assert.equal(readyHost.kills.length,0);await readyHost.ability.stop('/endpoint');assert.equal(readyHost.writes.at(-1).stopped,true);
 // 执行实际宿主源码：报告失败必须先停止子进程，确认退出后才发布错误。
 let host=hostHarness();host.start();await flush();
 host.state.report={phase:'PREFLIGHT_FAILED',code:'SAFE_FAILURE'};host.callbacks[0]();await flush();
 assert.deepEqual(host.kills,[20]);assert.equal(host.ability.childPid,-1);assert.equal(host.writes.at(-1).error,'SAFE_FAILURE');
 host=hostHarness();host.start();await flush();for(let i=0;i<301;i++)host.callbacks[0]();await flush();
 assert.deepEqual(host.kills,[20]);assert.equal(host.writes.at(-1).error,'engine_timeout');
 host=hostHarness();host.start();await flush();host.state.stopCode=5;
 await host.ability.stop('/endpoint');assert.equal(host.writes.at(-1).error,'stop_failed_5');assert.equal(host.ability.childPid,20);
 host=hostHarness();host.start();await flush();host.state.confirm=false;
 await host.ability.stop('/endpoint');assert.deepEqual(host.kills,[20]);assert.equal(host.writes.at(-1).error,'stop_timeout');assert.equal(host.ability.childPid,20);
 // 停止等待超过十秒后，异步启动才返回的PID仍必须正式回收。
 host=hostHarness();host.state.delayed=true;host.start();await host.ability.stop('/endpoint');
 assert.equal(host.writes.at(-1).error,'spawn_pending');host.resolve(45);await flush();
 assert.deepEqual(host.kills,[45]);assert.equal(host.writes.at(-1).stopped,true);assert.equal(host.callbacks.length,0);
 // 启动异常正文和安装路径不进入日志或端点。
 host=hostHarness();host.state.delayed=true;host.start();host.reject(Error('PRIVATE_TEST_MARKER'));await flush();
 assert.equal(host.writes.at(-1).error,'spawn_failed');assert(!JSON.stringify(host.writes.concat(host.logs)).includes('PRIVATE_TEST_MARKER'));assert(!host.logs.join(' ').includes('/installed'));
 // 迟到失败不能覆盖停止状态，也不能重新挂起轮询。
 host=hostHarness();host.state.delayed=true;host.start();await host.ability.stop('/endpoint');host.reject(Error('PRIVATE_TEST_MARKER'));await flush();
 assert.equal(host.writes.at(-1).stopped,true);assert.equal(host.callbacks.length,0);
 // 正式连接只在显式开关开启，失败/超时/迟到PID均确认broker回收。
 host=hostHarness();host.state.privateBroker=true;host.start();await flush();
 assert.deepEqual(host.brokerEvents,['create','host-start','attached']);
 const oldTick=host.callbacks[0];
 await host.ability.stop('/endpoint');assert.deepEqual(host.kills,[20]);assert(host.brokerEvents.includes('closed'));assert.equal(host.ability.brokerHandle,-1);
 host.start();await flush();host.cleared.length=0;oldTick();assert.deepEqual(host.cleared,[1]);assert.equal(host.callbacks.length,2);await host.ability.stop('/endpoint');
 host=hostHarness();host.state.privateBroker=true;host.state.delayed=true;host.start();await host.ability.stop('/endpoint');
 assert.equal(host.writes.at(-1).error,'spawn_pending');assert(!host.brokerEvents.includes('shutdown'));host.start();assert.equal(host.brokerEvents.filter(x=>x==='create').length,1);
 host.resolve(65);await flush();assert.deepEqual(host.kills,[65]);assert(host.brokerEvents.includes('closed'));assert.equal(host.writes.at(-1).stopped,true);
 host=hostHarness();host.state.privateBroker=true;host.state.delayed=true;host.start();host.reject(Error('fixed'));await flush();
 assert.equal(host.writes.at(-1).error,'spawn_failed');assert(host.brokerEvents.includes('closed'));
 host=hostHarness();host.state.privateBroker=true;host.start();await flush();host.state.brokerFail=true;await host.ability.stop('/endpoint');
 assert.deepEqual(host.kills,[20]);assert.equal(host.writes.at(-1).error,'broker_cleanup_failed');host.start();assert.equal(host.brokerEvents.filter(x=>x==='create').length,1);
 // 正式宿主始终回到原界面，不再携带测试入口或原生测试标记。
 host=hostHarness();let uiStarts=0;host.ability.context.startAbility=()=>{uiStarts++;return Promise.resolve();};host.ability.context.abilityInfo={bundleName:'test'};host.ability.onWindowStageCreate({loadContent(_page,callback){callback(null);}});assert.equal(uiStarts,1);
 // 生命周期真实顺序：onNewWant只处理引擎，随后onForeground才回跳。
 const navigationHost=hostHarness(), navigation=[];
 navigationHost.ability.context.abilityInfo={bundleName:'fixed.bundle'};
 navigationHost.ability.context.startAbility=want=>{navigation.push(want);return Promise.resolve();};
 navigationHost.ability.onForeground();assert.equal(navigation.length,0);
 let loaded;
 navigationHost.ability.onWindowStageCreate({loadContent(_page,callback){loaded=callback;}});
 navigationHost.ability.onForeground();assert.equal(navigation.length,0);
 loaded(null);assert.equal(navigation.length,1);
 const repeatWant={parameters:{installedRoot:'/installed',endpointFile:'/endpoint',dataRoot:'/data'}};
 async function deliver(want){const before=navigation.length;navigationHost.ability.onNewWant(want,{});await flush();assert.equal(navigation.length,before);navigationHost.ability.onForeground();assert.equal(navigation.length,before+1);}
 await deliver(repeatWant);await deliver(repeatWant);
 assert.equal(navigationHost.ability.childPid,20);assert.equal(navigation.length,3);
 navigationHost.state.stopCode=5;
 await deliver({parameters:{...repeatWant.parameters,action:'stop'}});
 assert.equal(navigationHost.writes.at(-1).error,'stop_failed_5');assert.equal(navigationHost.ability.childPid,20);
 navigationHost.state.stopCode=0;
 await deliver({parameters:{...repeatWant.parameters,action:'stop'}});
 assert.equal(navigationHost.writes.at(-1).stopped,true);assert.equal(navigationHost.ability.childPid,-1);
 await deliver(repeatWant);assert.equal(navigation.length,6);assert.equal(navigationHost.ability.childPid,21);
 for(const want of navigation){assert.equal(want.bundleName,'fixed.bundle');assert.equal(want.abilityName,'EntryAbility');assert.equal(want.parameters,undefined);}
 assert(!engineText.includes('runRealToolsProbe'));assert(!engineText.includes('real-tools-probe-v1'));
 const runtimeText=fs.readFileSync(path.join(root,'harmony/plugins/dsh_runtime_ohos/native/runtime_process.c'),'utf8');assert(!runtimeText.includes('DSH_HARMONY_REAL_TOOLS_PROBE'));assert(!runtimeText.includes('real-tools-probe-v1'));assert(runtimeText.includes('cursor != NULL'));
 console.log('主桥及宿主生命周期回归通过：含失败回收、超时回收、迟到PID及安全错误码');
})().catch(e=>{console.error(e);process.exitCode=1;});
