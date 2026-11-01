const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),assert=require('node:assert/strict');
const ts=require(process.argv[2]||'typescript');
const root=path.resolve(__dirname,'../../..');
const file=path.join(root,'harmony/tests/device-fixtures/entryability/ToolsProbeAbility.ets');
function harness(){
 const requests=[],reports=[],modes=[],exports={};let page;
 const js=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
 vm.runInNewContext(js,{exports,setTimeout:()=>1,clearTimeout(){},require:n=>n==='@kit.AbilityKit'?{UIAbility:class{}}:n==='@ohos.fileio'?{default:{chmodSync:(_p,m)=>modes.push(m)}}:n==='@kit.CoreFileKit'?{fileIo:{OpenMode:{CREATE:1,WRITE_ONLY:2,TRUNC:4},accessSync:()=>false,openSync:()=>({fd:3}),writeSync:(_fd,v)=>reports.push(JSON.parse(v)),closeSync(){}}}:n==='@kit.PerformanceAnalysisKit'?{hilog:{error(){}}}:(()=>{throw Error('未授权依赖:'+n)})()});
 const a=new exports.default();a.context={filesDir:'/module/files',getApplicationContext:()=>({filesDir:'/app/files'}),abilityInfo:{bundleName:'own.bundle'},startAbility:w=>{requests.push(w);return Promise.resolve()}};
 return {a,requests,reports,modes,validate:exports.validateToolReport,validateAcceptance:exports.validateLocalAcceptance,window(error=null){a.onWindowStageCreate({loadContent(p,cb){page=p;cb(error);}});assert.equal(page,'pages/Engine');}};
}
const valid={runRealToolsProbe:true,enablePrivateBroker:true,installedRoot:'/app/files/engine-110',dataRoot:'/module/files/engine-tools-probe-113',endpointFile:'/module/files/engine-tools-probe-113-endpoint.json'};
let h=harness();h.a.onCreate({parameters:valid},{});assert.equal(h.requests.length,0);h.window();assert.equal(h.requests.length,1);assert.equal(h.requests[0].abilityName,'EngineAbility');assert.equal(h.requests[0].bundleName,'own.bundle');assert.deepEqual(Object.keys(h.requests[0].parameters).sort(),Object.keys(valid).sort());h.window();assert.equal(h.requests.length,1);assert(h.modes.every(m=>m===0o644));assert(!JSON.stringify(h.reports).includes('/app/files'));
for(const patch of [{runRealToolsProbe:'true'},{enablePrivateBroker:false},{installedRoot:'/app/files/engine-110/../../secret'},{installedRoot:'/other/engine-110'},{dataRoot:'/app/files/engine-tools-probe-113'},{endpointFile:'/app/files/engine-endpoint.json'}]){h=harness();h.a.onCreate({parameters:{...valid,...patch}},{});assert.equal(h.reports.at(-1).stage,'rejected');h.window();assert.equal(h.requests.length,0);}
h=harness();h.a.context.getApplicationContext=()=>{throw new TypeError('PRIVATE_SENTINEL');};h.a.onCreate({parameters:valid},{});assert.equal(h.reports.at(-1).errorName,'TypeError');assert(!JSON.stringify(h.reports).includes('PRIVATE_SENTINEL'));h.window();assert.equal(h.requests.length,0);
h=harness();h.a.onCreate({parameters:valid},{});h.window({code:1,name:'BusinessError',message:'PRIVATE_SENTINEL'});assert.equal(h.requests.length,0);assert.equal(h.reports.at(-1).stage,'window-failed');assert(!JSON.stringify(h.reports).includes('PRIVATE_SENTINEL'));
const normal=fs.readFileSync(path.join(root,'app/ohos/entry/src/main/ets/entryability/EntryAbility.ets'),'utf8');assert(!/toolsProbe|legacyFileIo|onCreate\(|onWindowStageCreate\(/.test(normal));assert(normal.includes('super.configureFlutterEngine(flutterEngine)'));
console.log('纯UIAbility实际源码回归通过：窗口后单次转发、参数和路径拒绝、窗口/上下文失败安全诊断、恢复默认Flutter入口');

const validate=harness().validate;
const validateAcceptance=harness().validateAcceptance;
const acceptance={phase:'LOCAL_ACCEPTANCE_AWAITING_RESTART',stage:'complete',capabilityErrorCode:'',conversationStage:'complete',coldRead:false,passed:true,capabilitiesPassed:true,toolsPassed:true,conversationPassed:true,differentProcess:false,userEvent:true,assistantEvent:true,userPersisted:true,assistantPersisted:true,streamed:true,credentialHeaderAbsent:true,paidModelRequestSent:false,disposed:true,loopbackRequests:1,sseFrames:3,otherModelsBlocked:0};
assert.equal(validateAcceptance(JSON.stringify(acceptance)).status,'ready');
for(const invalid of [{...acceptance,token:'SECRET'},{...acceptance,conversationStage:'SECRET'},{...acceptance,paidModelRequestSent:true},{...acceptance,loopbackRequests:65536},{...acceptance,coldRead:'true'}])assert.equal(validateAcceptance(JSON.stringify(invalid)).status,'schema');
assert.equal(validateAcceptance(JSON.stringify({...acceptance,phase:'LOCAL_ACCEPTANCE_RUNNING'})).terminal,false);
assert.equal(validateAcceptance(JSON.stringify({...acceptance,phase:'LOCAL_ACCEPTANCE_COLD_READ_OK',coldRead:true,differentProcess:true})).terminal,true);
const report={phase:'REAL_TOOLS_PROBE_FAILED',stage:'setup',writeRead:false,readOnlyDenied:false,outsideDenied:false,concurrentWorkspaces:false,crossWriteDenied:false,revokeStopped:false,disposeConfirmed:true,modelAttemptsBlocked:0,modelRequestSent:false,errorCode:'EXTERNAL_ERROR',errorName:'TypeError'};
assert.equal(validate(JSON.stringify(report),false).status,'ready');
for(const invalid of [{...report,token:'SECRET'},{...report,errorCode:'PRIVATE_SENTINEL'},{...report,stage:'/private/path'},{...report,writeRead:'true'},{...report,modelRequestSent:true},{...report,modelAttemptsBlocked:-1}])assert.equal(validate(JSON.stringify(invalid),false).status,'schema');
assert.equal(validate('{',false).status,'parse');assert.equal(validate('a'.repeat(4097),false).status,'length');
assert.equal(validate(JSON.stringify({phase:'REAL_TOOLS_STARTING',modelRequestSent:false}),false).terminal,false);
assert.equal(validate(JSON.stringify({phase:'PREFLIGHT_FAILED',errorCode:'DSH_START_FAILED',modelRequestSent:false}),true).terminal,true);
assert.equal(validate(JSON.stringify({phase:'FAILED',errorCode:'SECRET',modelRequestSent:false}),true).status,'schema');
const polling=harness();polling.a.onCreate({parameters:valid},{});polling.window();
Promise.resolve().then(()=>{assert.equal(polling.reports.at(-1).stage,'mirror-polling');assert.equal(polling.reports.at(-1).resultMirror,'missing');assert.equal(polling.reports.at(-1).startupMirror,'missing');polling.a.mirrorRounds=299;polling.a.pollReports();assert.equal(polling.reports.at(-1).stage,'mirror-timeout');polling.a.onDestroy();console.log('安全报告镜像回归通过：白名单、未知字段拒绝、长度与解析分类、missing不误报工具失败、300轮上限');});

const diagnostic={toolIsError:true,resultMatches:false,partialMatches:false,valueType:'undefined',toolErrorCode:'CODE_RUN_FAILED'};
assert.equal(validate(JSON.stringify({...report,toolDiagnostic:diagnostic}),false).status,'ready');
for(const bad of [null,[],{...diagnostic,body:'SECRET'},{...diagnostic,toolIsError:'true'},{...diagnostic,valueType:'SECRET'},{...diagnostic,toolErrorCode:'SECRET'},{toolIsError:true,resultMatches:false,partialMatches:false,valueType:'undefined'}])assert.equal(validate(JSON.stringify({...report,toolDiagnostic:bad}),false).status,'schema');
console.log('115诊断白名单通过：精确五字段、布尔类型及值闭集；未知body/错误码/缺字段拒绝');

for(const kind of ['none','exception','invalid-output','worker-exit','timeout','abort','output-limit','protocol','sandbox-unavailable','other'])assert.equal(validate(JSON.stringify({...report,ptcErrorKind:kind}),false).status,'ready');
for(const code of ['CODE_RUN_FAILED','UNKNOWN_TOOL','INVALID_TOOL_OUTPUT','ABORTED','ABORTED_BEFORE_DISPATCH','FS_SANDBOX_DENIED','other'])assert.equal(validate(JSON.stringify({...report,bindingErrorCode:code}),false).status,'ready');
for(const bad of [{ptcErrorKind:'rawbody'},{ptcErrorKind:{message:'rawbody'}},{ptcErrorKind:null},{bindingErrorCode:'rawbody'},{bindingErrorCode:123},{bindingErrorCode:null},{message:'rawbody'}])assert.equal(validate(JSON.stringify({...report,...bad}),false).status,'schema');
console.log('116诊断白名单通过：可选顶层kind与binding码仅闭集，旧报告兼容，正文/对象/数值拒绝');

for(const code of ['none','EACCES','EPERM','EXDEV','ENOTSUP','EMLINK','EEXIST','ENOENT','ENOTDIR','EROFS','ENOSPC','EIO','other'])assert.equal(validate(JSON.stringify({...report,hookAvailable:true,linkErrorCode:code}),false).status,'ready');
for(const code of ['none','INVALID_ARGS','FS_ABORTED','FS_AMBIGUOUS_EDIT','FS_EDIT_NOT_FOUND','FS_IO_ERROR','FS_NOT_DIRECTORY','FS_NOT_FOUND','FS_NOT_OBSERVED','FS_NOT_REGULAR_FILE','FS_NOT_TEXT','FS_PERMISSION_DENIED','FS_STALE_VERSION','FS_TOO_LARGE'])assert.equal(validate(JSON.stringify({...report,bindingErrorCode:code}),false).status,'ready');
for(const bad of [{hookAvailable:'true'},{hookAvailable:null},{linkErrorCode:'PRIVATE_SENTINEL'},{linkErrorCode:{message:'PRIVATE_SENTINEL'}},{linkErrorCode:13}])assert.equal(validate(JSON.stringify({...report,...bad}),false).status,'schema');
console.log('117固定FS诊断回归通过：原始errno闭集、源码FS错误闭集、hook布尔；正文与错误类型拒绝');
