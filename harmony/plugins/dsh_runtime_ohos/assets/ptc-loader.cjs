const fs=require('node:fs'),crypto=require('node:crypto'),path=require('node:path');
const {Duplex,Writable}=require('node:stream');
const scriptFd=Number(process.env.DSH_PTC_SCRIPT_FD),controlFd=Number(process.env.DSH_PTC_CONTROL_FD),limit=Number(process.env.DSH_PTC_MAX_MESSAGE);
const libraryDirectory=process.env.DSH_HARMONY_NATIVE_LIBRARY_DIR;
if(![scriptFd,controlFd].every(n=>Number.isInteger(n)&&n>=20)||!Number.isSafeInteger(limit)||limit<1||limit>134217728)throw Error('IPC_STARTUP_INVALID');
process.dlopen({exports:{}},path.join(libraryDirectory,'libdsh_ptc_exit.so'));
const source=fs.readFileSync(scriptFd);fs.closeSync(scriptFd);
if(crypto.createHash('sha256').update(source).digest('hex')!=='e25ce53b26bb3e96e62cb7433f74612395f3865b4627a695d3d4fd42c4706790')throw Error('PTC_SOURCE_MISMATCH');
function makeFdDuplex(fs, Duplex, fd, shutdown) {
 let reading=false, pending=0, closed=false, closing=null;
 const finishClose=()=>{if(closing&&pending===0&&!closed){closed=true;fs.close(fd,error=>{const done=closing;closing=null;done(error);});}};
 return new Duplex({allowHalfOpen:true,highWaterMark:16384,
  read(){
   if(reading||closing||closed)return;
   reading=true;pending++;const buffer=Buffer.allocUnsafe(16384);
   const receive=()=>fs.read(fd,buffer,0,buffer.length,null,(error,count)=>{
    if(error&&error.code==='EINTR'&&!closing){receive();return;}
    reading=false;pending--;
    if(closing){finishClose();return;}
    if(error){this.destroy(error);return;}
    if(count===0){this.push(null);return;}
    if(this.push(buffer.subarray(0,count)))this._read();
   });receive();
  },
  write(chunk,encoding,callback){
   pending++;let offset=0;
   const send=()=>fs.write(fd,chunk,offset,chunk.length-offset,null,(error,count)=>{
    if(error&&error.code==='EINTR'&&!closing){send();return;}
    if(!error&&count>0){offset+=count;if(offset<chunk.length&&!closing){send();return;}}
    pending--;
    callback(error||(offset!==chunk.length?new Error('IPC_WRITE_INCOMPLETE'):null));finishClose();
   });send();
  },
  final(callback){try{shutdown.shutdownWrite();callback();}catch(error){callback(error);}},
  destroy(error,callback){
   if(closed){callback(error);return;}
   let shutdownError;try{shutdown.shutdownBoth();}catch(failure){shutdownError=failure;}
   closing=closeError=>callback(error||shutdownError||closeError);finishClose();
  }
 });
}


const shutdownModule={exports:{}};process.dlopen(shutdownModule,path.join(libraryDirectory,'libdsh_ptc_shutdown.so'));
globalThis[Symbol.for('dsh.ohos.ptc.control')]=()=>{if(process.env.DSH_SUBPROCESS_CONTROL!=='pipe')throw Error('IPC_MARKER_INVALID');delete process.env.DSH_SUBPROCESS_CONTROL;return makeFdDuplex(fs,Duplex,controlFd,shutdownModule.exports);};
function output(fd){return new Writable({write(chunk,encoding,callback){let offset=0;const send=()=>fs.write(fd,chunk,offset,chunk.length-offset,null,(error,count)=>{if(error&&error.code==='EINTR'){send();return;}if(!error&&count>0){offset+=count;if(offset<chunk.length){send();return;}}callback(error||(offset!==chunk.length?Error('IPC_OUTPUT_INCOMPLETE'):null));});send();}});}
Object.defineProperty(process,'stdout',{value:output(1)});Object.defineProperty(process,'stderr',{value:output(2)});
const text=source.toString('utf8'),anchor="function openInheritedControlChannel() {\n\tconst marker = process.env[SUBPROCESS_CONTROL_ENV];\n\tReflect.deleteProperty(process.env, SUBPROCESS_CONTROL_ENV);\n\tif (marker !== \"pipe\") throw new Error(\"subprocess control channel was not inherited\");\n\treturn new Socket({\n\t\tfd: 7,\n\t\treadable: true,\n\t\twritable: true,\n\t\tallowHalfOpen: true\n\t});\n}";
if(text.split(anchor).length!==2)throw Error('PTC_FACTORY_ANCHOR_MISMATCH');
const prepared=text.replace(anchor,"function openInheritedControlChannel() { const key=Symbol.for('dsh.ohos.ptc.control'); const factory=globalThis[key]; delete globalThis[key]; return factory(); }")+String.fromCharCode(10)+'//# sourceURL=dsh-isolated-process.mjs'+String.fromCharCode(10);

delete process.env.DSH_PTC_SCRIPT_FD;delete process.env.DSH_PTC_CONTROL_FD;delete process.env.DSH_PTC_MAX_MESSAGE;delete process.env.DSH_HARMONY_NATIVE_LIBRARY_DIR;
process.argv=['node','dsh-isolated-process.mjs',String(limit)];
import('data:text/javascript;base64,'+Buffer.from(prepared).toString('base64'));
