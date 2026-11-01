import { audio } from '@kit.AudioKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult,
  EventChannel, EventSink, StreamHandler
} from '@ohos/flutter_ohos';
import { pcm16Wave, pcmLevel } from './voice/pcm';

// 复用原语音通道；系统识别使用鸿蒙离线中文模型，录音只保留在内存。
export default class DshVoicePlugin implements FlutterPlugin, MethodCallHandler, StreamHandler {
  private methods: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null;
  private initializing: Promise<speechRecognizer.SpeechRecognitionEngine> | null = null;
  private attached: boolean = false;
  private capturer: audio.AudioCapturer | null = null;
  private generation: number = 0;
  private session: number = 0;
  private recognizing: boolean = false;
  private chunks: Uint8Array[] = [];
  private bytes: number = 0;
  private limit: number = 0;
  private timer: number = -1;
  private committed: string = '';
  private partial: string = '';
  private speechRemainder: Uint8Array = new Uint8Array(0);
  private systemReady: boolean = false;
  private resolveStarted: (() => void) | null = null;

  getUniqueClassName(): string { return 'DshVoicePlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.attached = true;
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/voice');
    this.methods.setMethodCallHandler(this);
    this.events = new EventChannel(binding.getBinaryMessenger(), 'dsh/voice/events');
    this.events.setStreamHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.attached = false;
    this.methods?.setMethodCallHandler(null);
    this.events?.setStreamHandler(null);
    this.sink = null;
    void this.cancelCurrent();
    this.engine?.shutdown();
    this.engine = null;
  }

  onListen(_args: Object, sink: EventSink): void { this.sink = sink; }
  onCancel(_args: Object): void { this.sink = null; void this.cancelCurrent(); }

  private emit(type: string, value?: string | number): void {
    if (!this.sink || this.session === 0) return;
    const event = new Map<string, Object>();
    event.set('type', type); event.set('sessionId', this.session);
    if (typeof value === 'string') event.set('text', value);
    if (typeof value === 'number') event.set(type === 'error' ? 'code' : 'value', value);
    this.sink.success(event);
  }

  private async recognitionEngine(): Promise<speechRecognizer.SpeechRecognitionEngine> {
    if (this.engine) return this.engine;
    if (!this.initializing) {
      this.initializing = speechRecognizer.createEngine({ language: 'zh-CN', online: 1 });
    }
    const pending = this.initializing;
    try {
      const engine = await pending;
      if (!this.attached) { engine.shutdown(); throw new Error('语音通道已关闭'); }
      this.engine = engine;
      return engine;
    } finally {
      if (this.initializing === pending) this.initializing = null;
    }
  }

  private async permission(): Promise<boolean> {
    const info = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    return (await abilityAccessCtrl.createAtManager().checkAccessToken(info.appInfo.accessTokenId, 'ohos.permission.MICROPHONE')) === 0;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.execute(call, result).catch(() => {
      const details = new Map<string, Object>(); details.set('code', 3);
      result.error('voice', '语音操作未完成', details);
    });
  }

  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    if (call.method === 'capabilities') {
      let available = false;
      if (canIUse('SystemCapability.AI.SpeechRecognizer')) {
        try { await this.recognitionEngine(); available = true; } catch (_) { /* 无离线模型时不宣称可识别。 */ }
      }
      const caps = new Map<string, Object>();
      caps.set('recognizer', available);
      caps.set('recorder', canIUse('SystemCapability.Multimedia.Audio.Capturer'));
      caps.set('systemUnreliable', false);
      caps.set('environmentId', 'harmony-corespeech-zh-CN-offline');
      result.success(caps); return;
    }
    if (call.method === 'requestPermission') {
      if (await this.permission()) { result.success('granted'); return; }
      const context = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
      if (!context) { result.success('denied'); return; }
      const response = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      result.success(response.authResults[0] === 0 ? 'granted' : response.dialogShownResults?.[0] === false ? 'blocked' : 'denied');
      return;
    }
    if (call.method === 'openSettings') {
      const context = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
      if (!context) throw new Error('应用界面不可用');
      await context.startAbility({ bundleName: 'com.huawei.hmos.settings', abilityName: 'com.huawei.hmos.settings.MainAbility',
        parameters: { 'settingsParam': 'application_info', 'bundleName': context.abilityInfo.bundleName } });
      result.success(null); return;
    }
    if (call.method === 'cancel') { await this.cancelCurrent(); result.success(null); return; }
    if (call.method === 'stop') {
      const generation = this.generation;
      const session = this.session;
      const recognizing = this.recognizing;
      await this.stopCapture();
      if (generation !== this.generation) { result.success(null); return; }
      if (recognizing && session > 0) { this.finishRecognition(); result.success(null); }
      else {
        const wave = this.bytes > 0 ? pcm16Wave(this.chunks, this.bytes) : null;
        this.chunks = []; this.bytes = 0; this.session = 0;
        result.success(wave);
      }
      return;
    }
    if (call.method !== 'startRecognizer' && call.method !== 'startRecorder') { result.notImplemented(); return; }
    const session: string | number | boolean | Object | null | undefined = call.argument('sessionId');
    if (typeof session !== 'number' || !Number.isSafeInteger(session) || session <= 0) throw new Error('无效语音会话');
    const language: string | number | boolean | Object | null | undefined = call.argument('language');
    if (call.method === 'startRecognizer' && typeof language === 'string' && !['zh', 'zh-CN'].includes(language)) {
      const details = new Map<string, Object>(); details.set('code', 12);
      result.error('language', '鸿蒙系统识别目前只支持离线中文', details); return;
    }
    if (!(await this.permission())) {
      const details = new Map<string, Object>(); details.set('code', 9);
      result.error('permission', '尚未获得麦克风权限', details); return;
    }
    await this.cancelCurrent();
    const generation = ++this.generation;
    this.session = session; this.recognizing = call.method === 'startRecognizer';
    const seconds: string | number | boolean | Object | null | undefined = call.argument('maxSeconds');
    const duration = typeof seconds === 'number' && Number.isFinite(seconds) ? Math.max(1, Math.min(600, Math.floor(seconds))) : 60;
    this.limit = duration * 32000;
    try {
      if (this.recognizing) {
        const engine = await this.recognitionEngine();
        if (generation !== this.generation) { result.success(null); return; }
        engine.setListener(this.listener(generation));
        let startTimer = -1;
        let resolveStart: (() => void) | null = null;
        const started = new Promise<void>((resolve) => {
          resolveStart = resolve; this.resolveStarted = resolve;
          startTimer = setTimeout(resolve, 5000);
        });
        try {
          engine.startListening({ sessionId: String(session), audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 } });
          await started;
        } finally {
          clearTimeout(startTimer);
          if (this.resolveStarted === resolveStart) this.resolveStarted = null;
        }
        if (generation !== this.generation) { result.success(null); return; }
        if (!this.systemReady) throw new Error('离线识别引擎未就绪');
      }
      const capturer = await audio.createAudioCapturer({ streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1, sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION, capturerFlags: 0 } });
      if (generation !== this.generation) { await capturer.release(); result.success(null); return; }
      this.capturer = capturer;
      capturer.on('readData', (data: ArrayBuffer) => {
        if (generation === this.generation && this.capturer === capturer) this.read(data);
      });
      await capturer.start();
      if (generation === this.generation) this.timer = setTimeout(() => { void this.reachLimit(generation); }, duration * 1000);
      result.success(null);
    } catch (_) {
      if (generation === this.generation) await this.cancelCurrent();
      throw new Error('语音设备启动失败');
    }
  }

  private listener(generation: number): speechRecognizer.RecognitionListener {
    const current = (id: string): boolean => generation === this.generation && id === String(this.session);
    return {
      onStart: (id: string, _message: string): void => {
        if (current(id)) { this.systemReady = true; this.resolveStarted?.(); }
      },
      onEvent: (_id: string, _code: number, _message: string): void => {},
      onResult: (id: string, value: speechRecognizer.SpeechRecognitionResult): void => {
        if (!current(id)) return;
        this.partial = value.result;
        if (value.isFinal) { this.committed += this.partial; this.partial = ''; }
        if (value.isLast) this.complete(); else this.emit('partial', this.committed + this.partial);
      },
      onComplete: (id: string, _message: string): void => { if (current(id)) this.complete(); },
      onError: (id: string, code: number, _message: string): void => {
        if (!current(id)) return;
        this.emit('error', code === 201 ? 9 : 5); this.emit('end');
        void this.cancelCurrent();
      }
    };
  }

  private complete(): void {
    this.emit('final', this.committed + this.partial); this.emit('end');
    void this.cancelCurrent();
  }

  private read(data: ArrayBuffer): void {
    const length = Math.min(data.byteLength - data.byteLength % 2, this.limit - this.bytes);
    if (length <= 0) return;
    const chunk = new Uint8Array(length); chunk.set(new Uint8Array(data, 0, length));
    this.emit('level', pcmLevel(chunk)); this.bytes += length;
    if (this.recognizing) {
      try { this.feedSpeech(chunk); }
      catch (_) { this.emit('error', 3); this.emit('end'); void this.cancelCurrent(); return; }
    } else this.chunks.push(chunk);
    if (this.bytes >= this.limit) void this.reachLimit(this.generation);
  }

  private async reachLimit(generation: number): Promise<void> {
    if (generation !== this.generation) return;
    await this.stopCapture();
    if (generation !== this.generation) return;
    if (this.recognizing) this.finishRecognition(); else this.emit('limit');
  }

  // 系统API只接收640或1280字节；采集缓冲区大小不作为协议帧大小。
  private feedSpeech(chunk: Uint8Array): void {
    const joined = new Uint8Array(this.speechRemainder.length + chunk.length);
    joined.set(this.speechRemainder); joined.set(chunk, this.speechRemainder.length);
    let offset = 0;
    while (offset + 640 <= joined.length) {
      this.engine?.writeAudio(String(this.session), joined.slice(offset, offset + 640)); offset += 640;
    }
    this.speechRemainder = joined.slice(offset);
  }

  private finishRecognition(): void {
    if (this.speechRemainder.length > 0) {
      const last = new Uint8Array(640); last.set(this.speechRemainder);
      this.engine?.writeAudio(String(this.session), last); this.speechRemainder = new Uint8Array(0);
    }
    this.engine?.finish(String(this.session));
  }

  private async stopCapture(): Promise<void> {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    const capturer = this.capturer; this.capturer = null;
    if (!capturer) return;
    try { capturer.off('readData'); } catch (_) {}
    try { await capturer.stop(); } catch (_) { this.emit('error', 3); }
    try { await capturer.release(); } catch (_) { this.emit('error', 3); }
  }

  // 后台、取消和销毁先退役会话；迟到的系统回调不能回填草稿或重开麦克风。
  async cancelCurrent(): Promise<void> {
    const session = this.session; const recognizing = this.recognizing;
    this.generation++; this.session = 0; this.recognizing = false;
    this.chunks = []; this.bytes = 0; this.committed = ''; this.partial = '';
    this.speechRemainder = new Uint8Array(0); this.systemReady = false;
    this.resolveStarted?.(); this.resolveStarted = null;
    if (recognizing && session > 0) { try { this.engine?.cancel(String(session)); } catch (_) {} }
    await this.stopCapture();
  }
}
