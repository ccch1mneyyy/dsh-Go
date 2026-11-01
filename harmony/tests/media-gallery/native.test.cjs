const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.argv[2]||'typescript');
function harness() {
 const files=new Map(),handles=new Map(),opened=[],calls=[];let next=0,targets=['file://media/Photo/fixed-test'],dialogGate,short=false,copyFail=false;
 const io={async mkdtemp(prefix){assert.match(prefix,/XXXXXX$/);return '/private/cache/dsh-gallery-fixed';},rmdirSync(){},OpenMode:{CREATE:1,READ_WRITE:2,EXCL:4,READ_ONLY:8,WRITE_ONLY:16},
  async open(name,mode){opened.push(name);if(mode&1)files.set(name,new Uint8Array(0));if(!files.has(name))files.set(name,new Uint8Array(0));const fd=++next;handles.set(fd,name);return {fd};},
  async write(fd,bytes){const value=new Uint8Array(bytes);files.set(handles.get(fd),value);return short?value.length-1:value.length;},
  async close(fd){handles.delete(fd);},async copyFile(a,b){if(copyFail)throw Error('复制失败');files.set(handles.get(b),files.get(handles.get(a)).slice());},
  statSync:fd=>({size:files.get(handles.get(fd)).length}),accessSync:p=>files.has(p),unlinkSync:p=>files.delete(p)};
 const helper={async showAssetsCreationDialog(sources,config){calls.push({sources,config});if(dialogGate)await dialogGate;return targets;},async release(){calls.push('released');}};
 const exports={};const source=fs.readFileSync(path.resolve(__dirname,'../../../app/ohos/entry/src/main/ets/plugins/DshMediaPlugin.ets'),'utf8');
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{exports,Uint8Array,ArrayBuffer,Date,
  AppStorage:{get:()=>({cacheDir:'/private/cache',abilityInfo:{bundleName:'fixed.test'}})},require:name=>({'@kit.AbilityKit':{},'@kit.CoreFileKit':{fileIo:io,fileUri:{getUriFromPath:p=>'file://fixed.test'+p}},'@kit.MediaLibraryKit':{photoAccessHelper:{PhotoType:{IMAGE:1},getPhotoAccessHelper:()=>helper}},'@ohos/flutter_ohos':{}}[name])});
 const plugin=new exports.default();const call=(args)=>new Promise(resolve=>plugin.onMethodCall({method:'saveImage',argument:k=>args[k]},{success:value=>resolve({ok:true,value}),error:code=>resolve({ok:false,code})}));
 return {call,files,handles,opened,calls,targets:value=>targets=value,gate:value=>dialogGate=value,short:()=>short=true,copyFail:()=>copyFail=true};
}
const args=()=>({bytes:new Uint8Array([1,2,3,4]),mime:'image/png',name:'测试.png'});
test('系统授权目标写入完整后才成功，并清理缓存和句柄',async()=>{
 const h=harness();const result=await h.call(args());assert.equal(result.ok,true);assert.equal(result.value,'file://media/Photo/fixed-test');
 assert.deepEqual(h.files.get(result.value),args().bytes);assert.equal(h.handles.size,0);assert.equal([...h.files.keys()].filter(x=>x.startsWith('/private/')).length,0);assert(h.calls.includes('released'));
});
test('用户取消不写图库、不伪报成功',async()=>{
 const h=harness();h.targets([]);assert.deepEqual(await h.call(args()),{ok:false,code:'permission'});assert.equal(h.files.size,0);assert.equal(h.handles.size,0);
});
test('错误URI不被当作系统图库授权',async()=>{
 const h=harness();h.targets(['/private/not-approved']);assert.equal((await h.call(args())).ok,false);assert(!h.opened.includes('/private/not-approved'));assert.equal(h.files.size,0);
});
test('临时写入不完整不展示授权弹窗',async()=>{
 const h=harness();h.short();assert.equal((await h.call(args())).ok,false);assert.equal(h.calls.length,0);assert.equal(h.files.size,0);assert.equal(h.handles.size,0);
});
test('复制失败不返回成功，临时源仍清理',async()=>{
 const h=harness();h.copyFail();assert.equal((await h.call(args())).ok,false);assert.equal(h.handles.size,0);assert.equal([...h.files.keys()].filter(x=>x.startsWith('/private/')).length,0);
});
test('无效类型和空图片不打开文件或系统图库',async()=>{
 const h=harness();assert.equal((await h.call({...args(),mime:'text/plain'})).code,'invalid');assert.equal((await h.call({...args(),bytes:new Uint8Array(0)})).code,'invalid');assert.equal(h.opened.length,0);
});
test('已有保存弹窗时拒绝重复请求，文件名不能越界',async()=>{
 const h=harness();let ready;h.gate(new Promise(r=>ready=r));const first=h.call({...args(),name:'../../敏感.png'});await new Promise(setImmediate);
 assert.equal((await h.call(args())).code,'busy');assert(!h.calls[0].config[0].title.includes('/'));ready();assert.equal((await first).ok,true);
});
