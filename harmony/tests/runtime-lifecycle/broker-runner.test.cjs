const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path'),{test}=require('node:test');
const ts=require(process.argv[2]||'typescript');
const source=fs.readFileSync(path.resolve(__dirname,'../device-fixtures/engineability/BrokerProbeRunner.ets'),'utf8');
async function run(overrides={}){
 const value={phase:'BROKER_CLIENT_OK',parallel:2,completed:2,stdoutVerified:true,stderrVerified:true,cancelled:true,exit7Verified:true,throwVerified:true,rejectVerified:true,exitCasesCompleted:3,exitDiagnosticClasses:['empty','fixed-throw','fixed-reject'],reaped:true,modelRequestSent:false,...overrides};
 let sent=false,final;const raw=new TextEncoder().encode(JSON.stringify(value)+'\n{"nativeReturn":0}\n');const exports={};
 const files={OpenMode:{},mkdirSync(){},openSync(){return {fd:1}},closeSync(){},writeSync(_fd,v){if(typeof v==='string')final=JSON.parse(v)}};
 const client={launch:()=>7,status:()=>({audit:sent?new Uint8Array():((sent=true),raw),auditErrno:0,exited:1,signal:0,auditEof:1}),release:()=>1,stop:()=>0};
 const modules={'@ohos.file.fs':{default:files},'@ohos.util':{default:{TextDecoder:class{decodeToString(b){return new TextDecoder().decode(b)}}}},'libbroker_client.so':{default:client},'libdsh_broker.so':{default:{create:()=>({handle:1,fd:64,error:0}),attached:()=>0,close:()=>0}},'libdsh_control.so':{default:{watch:()=>0,exited:()=>1,signal:()=>0,forget(){}}},'./HarmonyBrokerHost':{HarmonyBrokerHost:class{start(){}async shutdown(){}}},'./HarmonyTaskDriver':{HarmonyTaskDriver:class{accepts(){return true}}}};
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,{exports,require:n=>modules[n]||{},Uint8Array,Date,setTimeout});
 await exports.runBrokerProbe({filesDir:'/fixed',resourceManager:{getRawFileContent:async()=>new Uint8Array([1])}},'/installed');return final;
}
test('真实Runner接受三个退出例并要求所有成功门槛',async()=>{assert.equal((await run()).phase,'BROKER_PROBE_OK');for(const override of [{exit7Verified:false},{throwVerified:false},{rejectVerified:false},{exitCasesCompleted:2},{exitDiagnosticClasses:['empty','fixed-throw']}])assert.notEqual((await run(override)).phase,'BROKER_PROBE_OK')});
test('真实Runner拒绝非白名单/错误顺序/未知字段，保留固定退出错误码',async()=>{for(const override of [{exitDiagnosticClasses:['empty','raw-private','fixed-reject']},{exitDiagnosticClasses:['fixed-throw','empty','fixed-reject']},{unknown:true}])assert.equal((await run(override)).phase,'BROKER_PROBE_FAILED');const result=await run({phase:'BROKER_CLIENT_FAILED',code:'EXIT_CASE_FAILED',exitCasesCompleted:0,exitDiagnosticClasses:[]});assert.equal(result.phase,'BROKER_CLIENT_FAILED');assert.equal(result.client.code,'EXIT_CASE_FAILED')});
