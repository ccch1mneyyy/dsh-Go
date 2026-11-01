export type StreamName = 'stdout' | 'stderr' | 'control';
export interface ExitFacts { exitCode: number | null; signal: string | null; }
export interface SpawnSpec {
  kind: 'ptc-oneshot'; argv: string[]; cwd: string; envSet: Record<string, string>; envUnset: string[];
  stdio: { stdin: 'ignore'; stdout: 'pipe'; stderr: 'pipe'; control: 'pipe' }; graceMs: number;
}
export interface Task {
  read(stream: StreamName, maxBytes: number): { data: Uint8Array; eof: boolean };
  writeControl(data: Uint8Array): number;
  endControl(): void;
  stop(): void;
  pollExit(): ExitFacts | null;
  reap(): Promise<void>;
}
export interface Codec {
  encodeText(text: string): Uint8Array;
  decodeText(data: Uint8Array): string;
  base64(data: Uint8Array): string;
  unbase64(text: string): Uint8Array;
}
export class Cancellation {
  aborted = false;
  private listeners = new Set<() => void>();
  subscribe(listener: () => void): () => void {
    if(this.aborted)listener();else this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }
  cancel(): void { if(this.aborted)return;this.aborted=true;for(const listener of this.listeners){try{listener();}catch(_){/* 取消通知异常不能阻止其他任务回收。 */}}this.listeners.clear(); }
}
export interface StartFailure { startFailed: true; reaped: true; code: string; }
export interface TaskDriver {
  // 失败需显式确认无存活/待返回资源；普通Promise拒绝属于状态未知，不得宣称已回收。
  start(spec: SpawnSpec, signal: Cancellation): Promise<Task | StartFailure>;
}
interface State {
  id: number; abort: Cancellation; task?: Task; stopping: boolean; end: boolean;
  credit: Record<StreamName, number>; eof: Record<StreamName, boolean>;
  write?: { seq: number; data: Uint8Array; offset: number }; seq: number; exit: boolean; reaping: boolean;
}
const names: StreamName[] = ['stdout', 'stderr', 'control'];
const signals = ['SIGKILL','SIGTERM','SIGABRT','SIGSEGV','SIGBUS','SIGILL','SIGFPE','SIGSYS','SIGINT','SIGHUP','SIGPIPE'];
const LIMIT = 1048576, WINDOW = 65536;
function validExit(value: ExitFacts): boolean {
  return value.signal===null ? typeof value.exitCode==='number'&&Number.isInteger(value.exitCode)&&value.exitCode>=0&&value.exitCode<=255 : value.exitCode===null&&signals.includes(value.signal);
}
/** 纯协议状态机；调用方须持续pump，断连调用disconnect并保留对象至settled。 */
export class ParentBroker {
  private input = new Uint8Array(0);
  private output: Uint8Array[] = [];
  private outputBytes = 0;
  private states = new Map<number, State>();
  private pending = new Set<Promise<void>>();
  private lastId = 0;
  private closed = false;
  failure: string | null = null;
  constructor(private generation: string, private driver: TaskDriver,
    private writeTransport: (data: Uint8Array)=>number,
    private allowSpec: (spec: SpawnSpec)=>boolean, private codec: Codec) {}
  private track(promise: Promise<void>): void {
    this.pending.add(promise); promise.finally(()=>this.pending.delete(promise)).catch(()=>{});
  }
  private send(id: number, type: string, fields: object = {}): void {
    if(this.closed)return;
    const body=this.codec.encodeText(JSON.stringify({v:1,generation:this.generation,id,type,...fields}));
    if(body.length>LIMIT||this.outputBytes+body.length+4>LIMIT*2)throw Error('OUTPUT_LIMIT');
    const wire=new Uint8Array(body.length+4);new DataView(wire.buffer).setUint32(0,body.length);wire.set(body,4);
    this.output.push(wire);this.outputBytes+=wire.length;
  }
  accept(chunk: Uint8Array): void {
    if(this.closed)return;
    try {
      // 传输层单次读取须受限，避免分帧前无界申请。
      if(chunk.length>LIMIT+4)throw Error('CHUNK_LIMIT');
      const input=new Uint8Array(this.input.length+chunk.length);input.set(this.input);input.set(chunk,this.input.length);this.input=input;
      while(this.input.length>=4){
        const size=new DataView(this.input.buffer,this.input.byteOffset,4).getUint32(0);
        if(!size||size>LIMIT)throw Error('FRAME_LIMIT');if(this.input.length<size+4)break;
        const frame=JSON.parse(this.codec.decodeText(this.input.slice(4,size+4)));
        this.input=this.input.slice(size+4);this.receive(frame);
      }
    }catch(_){this.disconnect('BROKER_PROTOCOL_FAILED');}
  }
  private receive(frame: Record<string, any>): void {
    if(frame.v!==1||frame.generation!==this.generation||!Number.isSafeInteger(frame.id)||frame.id<=0)throw Error('IDENTITY');
    if(frame.type==='spawn'){
      const spec=frame.spec as SpawnSpec;
      if(frame.id<=this.lastId||this.states.has(frame.id)||!spec||spec.kind!=='ptc-oneshot'||
        !Array.isArray(spec.argv)||!spec.argv.every(x=>typeof x==='string')||typeof spec.cwd!=='string'||
        !spec.envSet||typeof spec.envSet!=='object'||Array.isArray(spec.envSet)||!Object.values(spec.envSet).every(x=>typeof x==='string')||
        !Array.isArray(spec.envUnset)||!spec.envUnset.every(x=>typeof x==='string')||
        !Number.isInteger(spec.graceMs)||spec.graceMs<0||spec.graceMs>30000||
        spec.stdio?.stdin!=='ignore'||spec.stdio.stdout!=='pipe'||spec.stdio.stderr!=='pipe'||spec.stdio.control!=='pipe'||!this.allowSpec(spec))throw Error('SPAWN_SPEC');
      this.lastId=frame.id;
      const state:State={id:frame.id,abort:new Cancellation(),stopping:false,end:false,
        credit:{stdout:0,stderr:0,control:0},eof:{stdout:false,stderr:false,control:false},seq:0,exit:false,reaping:false};
      this.states.set(state.id,state);
      const started=Promise.resolve().then(()=>this.driver.start(spec,state.abort)).then(task=>{
        if ('startFailed' in task) {
          if(task.reaped!==true || !/^[A-Z0-9_]{1,80}$/.test(task.code))throw Error('START_UNKNOWN');
          this.states.delete(state.id);this.send(state.id,'spawnError',{code:task.code,reaped:true});return;
        }
        state.task=task;
        if(this.closed){this.cleanup(state);return;}
        this.send(state.id,'spawned');if(state.stopping)task.stop();if(state.end)task.endControl();
      }).catch(()=>{this.disconnect('BROKER_DRIVER_FAILED');});
      this.track(started);return;
    }
    const state=this.states.get(frame.id);if(!state)throw Error('UNKNOWN_TASK');
    if(frame.type==='stop'){
      if(!state.stopping){state.stopping=true;state.abort.cancel();state.task?.stop();}return;
    }
    if(frame.type==='end'){
      if(!state.end){state.end=true;if(!state.write)state.task?.endControl();}return;
    }
    if(frame.type==='readCredit'){
      const stream=frame.stream as StreamName;
      if(!names.includes(stream)||!Number.isSafeInteger(frame.bytes)||frame.bytes<=0||state.credit[stream]+frame.bytes>WINDOW)throw Error('CREDIT');
      if(!state.eof[stream])state.credit[stream]+=frame.bytes;return;
    }
    if(frame.type==='write'){
      if(!state.task||state.end||state.exit||state.write||frame.seq!==state.seq+1||typeof frame.data!=='string')throw Error('WRITE');
      const data=this.codec.unbase64(frame.data);if(this.codec.base64(data)!==frame.data)throw Error('BASE64');if(!data.length||data.length>WINDOW)throw Error('WRITE_LIMIT');
      state.seq=frame.seq;state.write={seq:frame.seq,data,offset:0};return;
    }
    throw Error('MESSAGE');
  }
  pump(): void {
    if(this.closed)return;
    try {
      for(const state of this.states.values()){
        const task=state.task;if(!task||state.reaping)continue;
        if(state.write){
          const pending=state.write;const bytes=pending.data.slice(pending.offset);const count=task.writeControl(bytes);
          if(!Number.isInteger(count)||count<0||count>bytes.length)throw Error('SHORT_WRITE');
          pending.offset+=count;
          if(pending.offset===pending.data.length){state.write=undefined;this.send(state.id,'writeAck',{seq:pending.seq});if(state.end)task.endControl();}
        }
        for(const stream of names){
          if(state.eof[stream])continue;
          // 0额度下只能探测EOF；driver不得消费未授权字节。
          const read=task.read(stream,state.credit[stream]);
          if(read.data.length>state.credit[stream]||typeof read.eof!=='boolean')throw Error('DRIVER_CREDIT');
          if(read.data.length){state.credit[stream]-=read.data.length;this.send(state.id,'data',{stream,data:this.codec.base64(read.data)});}
          if(read.eof){state.eof[stream]=true;this.send(state.id,'eof',{stream});}
        }
        if(!state.exit&&names.every(stream=>state.eof[stream])){
          const facts=task.pollExit();if(facts===null)continue;if(!validExit(facts))throw Error('EXIT_STATUS');
          state.exit=true;this.send(state.id,'exit',facts);state.reaping=true;
          this.track(Promise.resolve().then(()=>task.reap()).then(()=>{this.states.delete(state.id);this.send(state.id,'reaped');}).catch(()=>this.disconnect('BROKER_REAP_FAILED')));
        }
      }
      while(this.output.length){
        const frame=this.output[0],count=this.writeTransport(frame);
        if(!Number.isInteger(count)||count<0||count>frame.length)throw Error('TRANSPORT_WRITE');if(!count)break;
        this.outputBytes-=count;if(count===frame.length)this.output.shift();else{this.output[0]=frame.slice(count);break;}
      }
    }catch(_){this.disconnect('BROKER_DRIVER_FAILED');}
  }
  private cleanup(state: State): void {
    if(!state.task||state.reaping)return;state.reaping=true;
    try{state.task.stop();}catch(_){this.failure='BROKER_STOP_FAILED';}
    this.track(Promise.resolve().then(()=>state.task!.reap()).then(()=>{this.states.delete(state.id);}).catch(()=>{this.failure='BROKER_REAP_FAILED';}));
  }
  disconnect(code='BROKER_DISCONNECTED'): void {
    if(this.closed)return;this.closed=true;this.failure=code;this.output=[];this.outputBytes=0;
    for(const state of this.states.values()){state.abort.cancel();this.cleanup(state);}
  }
  async settled(): Promise<void> {
    while(this.pending.size)await Promise.allSettled([...this.pending]);
    if(this.states.size)throw Error('BROKER_CLEANUP_INCOMPLETE');
  }
}
