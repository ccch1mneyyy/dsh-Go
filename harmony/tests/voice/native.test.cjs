const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.argv[2]||'typescript');
const root=path.resolve(__dirname,'../../..');
function compile(file,dependencies,extra={}) {
 const exports={};const source=fs.readFileSync(path.join(root,file),'utf8');
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,{exports,require:n=>dependencies[n],Uint8Array,ArrayBuffer,DataView,Map,canIUse:()=>true,...extra});
 return exports;
}
const pcm=compile('app/ohos/entry/src/main/ets/plugins/voice/pcm.ets',{});
function harness() {
 let listener,read,timer,permission=true,startAuto=true,engineGate,releaseGate,opened=0,released=0,shutdown=0;
 const sent=[],writes=[],finishes=[],cancels=[];
 const engine={setListener:x=>listener=x,startListening(params){if(startAuto)listener.onStart(params.sessionId,'');},writeAudio:(id,data)=>writes.push({id,data}),finish:id=>finishes.push(id),cancel:id=>cancels.push(id),shutdown:()=>shutdown++};
 const makeCapturer=async()=>{opened++;return {on:(_name,callback)=>read=callback,off(){},async start(){},async stop(){if(releaseGate)await releaseGate;},async release(){released++;}};};
 const {default:Plugin}=compile('app/ohos/entry/src/main/ets/plugins/DshVoicePlugin.ets',{
  '@kit.AudioKit':{audio:{createAudioCapturer:makeCapturer,AudioSamplingRate:{SAMPLE_RATE_16000:16000},AudioChannel:{CHANNEL_1:1},AudioSampleFormat:{SAMPLE_FORMAT_S16LE:1},AudioEncodingType:{ENCODING_TYPE_RAW:0},SourceType:{SOURCE_TYPE_VOICE_RECOGNITION:1}}},
  '@kit.CoreSpeechKit':{speechRecognizer:{async createEngine(){if(engineGate)await engineGate;return engine;}}},
  '@kit.AbilityKit':{bundleManager:{BundleFlag:{},async getBundleInfoForSelf(){return {appInfo:{accessTokenId:1}};}},abilityAccessCtrl:{createAtManager:()=>({async checkAccessToken(){return permission?0:-1;}})}},
  '@ohos/flutter_ohos':{MethodChannel:class{setMethodCallHandler(){}},EventChannel:class{setStreamHandler(){}}},'./voice/pcm':pcm
 },{setTimeout:callback=>{timer=callback;return 1;},clearTimeout:()=>{timer=null;}});
 const plugin=new Plugin();plugin.onAttachedToEngine({getBinaryMessenger(){}});plugin.onListen({}, {success:e=>sent.push(Object.fromEntries(e))});
 const call=(method,args={})=>new Promise((resolve,reject)=>plugin.onMethodCall({method,argument:n=>args[n]}, {success:resolve,error:(code,_message,details)=>reject(Object.assign(Error(code),{details})),notImplemented:()=>reject(Error('未实现'))}));
 return {plugin,call,sent,writes,finishes,cancels,permission:v=>permission=v,startAuto:v=>startAuto=v,engineGate:v=>engineGate=v,releaseGate:v=>releaseGate=v,read:data=>read(data),listener:()=>listener,limit:()=>timer?.(),opened:()=>opened,released:()=>released,shutdown:()=>shutdown};
}
test('能力探测不录音，销毁释放离线引擎',async()=>{
 const h=harness();const result=Object.fromEntries(await h.call('capabilities'));
 assert.equal(result.recognizer,true);assert.equal(h.opened(),0);
 h.plugin.onDetachedFromEngine({});assert.equal(h.shutdown(),1);
});
test('未授权与不支持的语言不会打开麦克风',async()=>{
 const h=harness();h.permission(false);
 await assert.rejects(h.call('startRecorder',{sessionId:1}),e=>e.details.get('code')===9);
 h.permission(true);await assert.rejects(h.call('startRecognizer',{sessionId:2,language:'en-US'}),e=>e.details.get('code')===12);
 assert.equal(h.opened(),0);
});
test('PCM录音生成规范16k单声道WAV，音量有界且停止释放',async()=>{
 const h=harness();await h.call('startRecorder',{sessionId:11,maxSeconds:2});
 const raw=new Uint8Array([0,0,255,127,0,128,4,0]);h.read(raw.buffer);
 const wav=await h.call('stop');assert.equal(Buffer.from(wav.subarray(0,4)).toString(),'RIFF');
 const view=new DataView(wav.buffer);assert.equal(view.getUint32(24,true),16000);assert.equal(view.getUint16(22,true),1);assert.equal(view.getUint32(40,true),8);
 assert.deepEqual(wav.subarray(44),raw);assert.equal(h.released(),1);
 assert(h.sent.some(e=>e.type==='level'&&e.value>=0&&e.value<=1));
});
test('取消未完成的引擎初始化不会迟到开启麦克风',async()=>{
 const h=harness();let resolve;h.engineGate(new Promise(r=>resolve=r));
 const start=h.call('startRecognizer',{sessionId:12});await new Promise(setImmediate);
 await h.call('cancel');resolve();await start;assert.equal(h.opened(),0);assert.equal(h.sent.length,0);
});
test('多子句识别仍使用原会话事件，最终结果只发一次',async()=>{
 const h=harness();await h.call('startRecognizer',{sessionId:21});const listener=h.listener();
 h.read(new Uint8Array(200).buffer);assert.equal(h.writes.length,0);h.read(new Uint8Array(440).buffer);assert.equal(h.writes[0].id,'21');assert.equal(h.writes[0].data.length,640);
 listener.onResult('21',{result:'鸿蒙',isFinal:true,isLast:false});
 listener.onResult('21',{result:'语音',isFinal:false,isLast:false});
 listener.onResult('21',{result:'测试',isFinal:true,isLast:true});
 listener.onComplete('21','');await new Promise(setImmediate);
 assert.deepEqual(h.sent.filter(e=>e.type==='partial').map(e=>e.text),['鸿蒙','鸿蒙语音']);
 assert.deepEqual(h.sent.filter(e=>e.type==='final').map(e=>e.text),['鸿蒙测试']);assert.equal(h.released(),1);
 listener.onError('21',201,'私密系统信息不记录');assert.equal(h.sent.filter(e=>e.type==='error').length,0);
});
test('取消后旧回调不会污染新会话',async()=>{
 const h=harness();await h.call('startRecognizer',{sessionId:31});const old=h.listener();await h.call('cancel');
 await h.call('startRecognizer',{sessionId:32});old.onResult('31',{result:'旧内容',isFinal:true,isLast:true});
 assert.equal(h.sent.length,0);await h.call('cancel');assert.equal(h.released(),2);
});
test('录音上限停止采集并保留已录字节供原UI取回',async()=>{
 const h=harness();await h.call('startRecorder',{sessionId:41,maxSeconds:1});h.read(new Uint8Array(40000).buffer);await new Promise(setImmediate);
 assert.equal(h.sent.filter(e=>e.type==='limit').length,1);assert.equal(h.released(),1);
 const wave=await h.call('stop');assert.equal(wave.length,32044);
});
test('停止期间取消和重开后，不会结束新识别会话',async()=>{
 const h=harness();await h.call('startRecognizer',{sessionId:51});let finish;h.releaseGate(new Promise(r=>finish=r));
 const stop=h.call('stop');await new Promise(setImmediate);await h.call('cancel');
 await h.call('startRecognizer',{sessionId:52});finish();await stop;assert.deepEqual(h.finishes,[]);
 h.releaseGate(null);await h.call('cancel');
});

test('系统开始回调确认前不录音，取消会退役等待',async()=>{
 const h=harness();h.startAuto(false);const start=h.call('startRecognizer',{sessionId:61});await new Promise(setImmediate);assert.equal(h.opened(),0);await h.call('cancel');await start;assert.equal(h.opened(),0);
});
test('系统开始超时返回错误而不打开麦克风',async()=>{
 const h=harness();h.startAuto(false);const start=h.call('startRecognizer',{sessionId:62});const rejected=assert.rejects(start,/voice/);await new Promise(setImmediate);h.limit();await rejected;assert.equal(h.opened(),0);
});
test('短尾帧仅补零至系统640字节要求，停止后旧音频不再写入',async()=>{
 const h=harness();await h.call('startRecognizer',{sessionId:63});h.read(new Uint8Array([1,2,3,4]).buffer);assert.equal(h.writes.length,0);await h.call('stop');assert.equal(h.writes.length,1);assert.equal(h.writes[0].data.length,640);assert.deepEqual(h.writes[0].data.subarray(0,4),new Uint8Array([1,2,3,4]));assert(h.writes[0].data.subarray(4).every(x=>x===0));h.read(new Uint8Array(640).buffer);assert.equal(h.writes.length,1);await h.call('cancel');
});
