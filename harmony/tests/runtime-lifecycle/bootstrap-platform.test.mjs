import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { Duplex } from 'node:stream';
import { prepareOhosRuntime, brokerOptions } from '../../plugins/dsh_runtime_ohos/assets/ohos-runtime-setup.mjs';
import { createOhosSubprocessProvider } from '../../plugins/dsh_runtime_ohos/assets/subprocess-ohos.mjs';
const original=process.argv[2],work=process.argv[3];if(!original||!work)throw Error('需固定原源码和D盘测试工作目录');
fs.mkdirSync(work,{recursive:true});
const root=fs.mkdtempSync(path.join(work,'fixed-'));const lib=path.join(root,'opt/dsh/node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib');fs.mkdirSync(lib,{recursive:true});fs.mkdirSync(path.join(root,'transport'));
fs.copyFileSync(original,path.join(lib,'index.js'));fs.writeFileSync(path.join(root,'transport/cordis-min.yml'),'- id: ptc-runtime\n  disabled: false\n');
fs.mkdirSync(path.join(root,'dsh-home'));fs.writeFileSync(path.join(root,'dsh-home/cordis.patch.yml'),'USER_TEST_SENTINEL');
const env={DSH_HARMONY_BROKER_FD:'64',DSH_HARMONY_BROKER_GENERATION:'engine-1-123'};
test('默认不生成平台资产，半配置拒绝且不读取其他env属性',()=>{
 assert.equal(prepareOhosRuntime(root,{}),path.join(root,'transport/cordis-min.yml'));assert(!fs.existsSync(path.join(lib,'ohos-index.js')));
 assert.throws(()=>brokerOptions({DSH_HARMONY_BROKER_FD:'64'}),/INVALID/);
 const guarded={...env};Object.defineProperty(guarded,'UNRELATED_PRIVATE',{get(){throw Error('禁止读取')}});assert.equal(brokerOptions(guarded).fd,64);
});
test('固定源生成同包入口，原Loader补丁实际禁旧插新，保留用户文件',()=>{
 const output=prepareOhosRuntime(root,env);assert.equal(prepareOhosRuntime(root,env),output);
 assert.equal(fs.readFileSync(path.join(lib,'index.js'),'utf8'),fs.readFileSync(original,'utf8'));
 assert.equal(fs.readFileSync(path.join(root,'dsh-home/cordis.patch.yml'),'utf8'),'USER_TEST_SENTINEL');
 const modules=path.resolve(path.dirname(original),'../../..');const require=createRequire(path.join(modules,'probe.cjs'));
 const yaml=require('js-yaml');const patches=yaml.load(fs.readFileSync(output,'utf8'));
 const boot=fs.readFileSync(path.join(modules,'@deepseek-ai/dsh-app-boot/lib/index.js'),'utf8');
 const start=boot.indexOf('function applyEntryPatches('),end=boot.indexOf('\n/** Loader entry tree',start);
 const scope={structuredClone};vm.createContext(scope);vm.runInContext(boot.slice(start,end)+'\nglobalThis.apply=applyEntryPatches;',scope);
 const rows=scope.apply([{id:'subprocess',name:'original'},{id:'subprocess-local'},{id:'ptc-runtime',name:'original'},{id:'ptc-runtime-node'}],patches,()=>{});
 assert(rows.slice(0,4).every(row=>row.disabled===true));assert.equal(rows.at(-1).id,'ohos-isolated-ptc');assert.equal(rows.at(-1).config.executionMode,'per-call');assert.equal(rows.at(-1).config.launch.executable,'/ohos/node');
 assert.equal(fileURLToPath(rows.at(-1).name),path.join(lib,'ohos-index.js'));
 fs.writeFileSync(path.join(lib,'ohos-index.js'),'USER_CUSTOM_GENERATED');assert.throws(()=>prepareOhosRuntime(root,env),/CONFLICT/);assert.equal(fs.readFileSync(path.join(lib,'ohos-index.js'),'utf8'),'USER_CUSTOM_GENERATED');
});
test('真实Loader插件apply装配正式factory，只接私有FD与根cwd',async()=>{
 const source=fs.readFileSync(new URL('../../plugins/dsh_runtime_ohos/assets/subprocess-ohos-loader.mjs',import.meta.url),'utf8');
 const functionCode=source.slice(source.indexOf('export default function apply')).replace('export default function','function').replaceAll('import.meta.url','moduleUrl');
 let seen,runtime;class Socket extends Duplex{constructor(options){super();seen=options}_read(){}_write(_data,_encoding,callback){callback()}}
 const modules=path.resolve(path.dirname(original),'../../..');
 const {Context}=await import(pathToFileURL(path.join(modules,'@deepseek-ai/cordis/lib/index.js')).href);
 const {SubprocessRuntime:Base}=await import(pathToFileURL(path.join(modules,'@deepseek-ai/dsh-subprocess/lib/index.js')).href);
 const scope={URL,Socket,path,fileURLToPath,SubprocessRuntime:Base,createOhosSubprocessProvider,brokerOptions,process:{env},moduleUrl:pathToFileURL(path.join(root,'transport/subprocess-ohos-loader.mjs')).href};vm.createContext(scope);vm.runInContext(functionCode+'\nglobalThis.mount=apply;',scope);
 const ctx=new Context();const mounted=ctx.plugin(scope.mount);await mounted;runtime=ctx.get('subprocess');assert(runtime);
 assert.equal(seen.fd,64);assert.equal(runtime.ohosIsolatedPtc,true);
 assert.throws(()=>runtime.spawn({argv:['/ohos/node','--max-old-space-size=512',path.join(lib,'process.js'),'65536'],cwd:'/user/workspace',env:{},stdio:{stdin:'ignore',stdout:'pipe',stderr:'pipe',control:'pipe'},graceMs:3000}),/UNSUPPORTED/);
 await mounted.dispose();assert.equal(ctx.get('subprocess'),undefined);
});
