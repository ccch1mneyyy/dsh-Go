import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import childProcessManager from '@ohos.app.ability.childProcessManager';
import { ChildProcessArgs } from '@ohos.app.ability.ChildProcessArgs';
import { Want } from '@kit.AbilityKit';
import type { ChildProcessOptions } from '@ohos.app.ability.ChildProcessOptions';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { connection } from '@kit.NetworkKit';
import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult,
  EventChannel, EventSink, StreamHandler
} from '@ohos/flutter_ohos';

/**
 * 鸿蒙本机引擎通道（对应 Dart 侧 `dsh/runtime` + `dsh/runtime/events`）。
 *
 * 最小闭环：install（解压打进 HAP 的 dsh-runtime.zip）→ start（原生子进程跑
 * libnode + bootstrap.mjs）→ getStatus 返回 running 与 baseUrl/token → stop。
 *
 * 尚未实现（变更操作明确拒绝，只读能力查询返回不可用）：安全模式、LKG 恢复、managed skills、
 * 手机存储挂载、后台诊断。这些在 Android 侧依赖 Linux rootfs，鸿蒙侧要另行适配。
 */
const TAG = 'DshRuntime';
const DOMAIN = 0x0001;

export default class DshRuntimePlugin implements FlutterPlugin, MethodCallHandler, StreamHandler {
  private channel: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private context: common.Context | null = null;
  private phase: string = 'notInstalled';
  private error: string | null = null;
  private baseUrl: string | null = null;
  private token: string | null = null;
  private workspaceDir: string | null = null;
  private childPid: number = -1;
  private startPromise: Promise<void> | null = null;
  private stopPromise: Promise<void> | null = null;
  private generation: number = 0;
  private installedVersion: string | null = null;

  private filesDir(): string {
    return (this.context as common.Context).filesDir;
  }

  private engineRoot(): string {
    if (this.engineDir) return this.engineDir;
    try {
      let best = '';
      let bestTime = 0;
      for (const name of fs.listFileSync(this.filesDir())) {
        if (!name.startsWith('engine-')) continue;
        const candidate = this.filesDir() + '/' + name;
        if (!fs.accessSync(candidate + '/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js')) continue;
        let mtime = 0;
        try { mtime = fs.statSync(candidate).mtime; } catch (error) { mtime = 0; }
        if (mtime >= bestTime) { bestTime = mtime; best = candidate; }
      }
      if (best) { this.engineDir = best; return best; }
    } catch (error) {
      // 目录列表失败时退化为新目录。
    }
    this.engineDir = this.filesDir() + '/engine-' + Date.now();
    return this.engineDir;
  }

  private dataRoot(): string {
    return this.filesDir() + '/engine-data';
  }

  private engineDir: string = '';

  private endpointFile(): string {
    return this.filesDir() + '/engine-endpoint.json';
  }

  getUniqueClassName(): string {
    return 'DshRuntimePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    hilog.info(DOMAIN, TAG, 'attached to engine');
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/runtime');
    this.channel.setMethodCallHandler(this);
    this.events = new EventChannel(binding.getBinaryMessenger(), 'dsh/runtime/events');
    this.events.setStreamHandler(this);
    this.refreshInstalled();
    this.refreshRunning();
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.events?.setStreamHandler(null);
    this.channel = null;
    this.events = null;
    this.context = null;
  }

  onListen(args: Object, sink: EventSink): void {
    hilog.info(DOMAIN, TAG, 'events onListen');
    this.sink = sink;
    this.emit();
  }

  onCancel(args: Object): void {
    this.sink = null;
  }

  private emit(): void {
    if (!this.sink) {
      hilog.info(DOMAIN, TAG, 'emit skipped: no sink');
      return;
    }
    try {
      const payload: Map<string, Object> = new Map();
      payload.set('type', 'status');
      payload.set('status', this.statusMap());
      this.sink.success(payload);
    } catch (error) {
      // 事件通道已关闭时忽略。
    }
  }

  /** 引擎目录里的启动脚本过期（缺新补丁）时需要重新解压。 */
  private needsReinstall(): boolean {
    try {
      const script = this.engineRoot() + '/transport/run-loopback-smoke.mjs';
      if (!fs.accessSync(script)) return true;
      return !fs.readTextSync(script).includes('scriptver-153');
    } catch (error) {
      return true;
    }
  }

  private hasEngine(): boolean {
    return fs.accessSync(this.engineRoot() + '/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js');
  }

  private refreshInstalled(): void {
    if (this.phase === 'running' || this.phase === 'starting') return;
    // 端点已存在说明引擎此前已启动成功（App 重启后要能直接回到 running）。
    const endpoint = this.endpointFile();
    try {
      if (fs.accessSync(endpoint)) {
        const parsed = this.readEndpoint(endpoint);
        if (parsed !== null && parsed['baseUrl'] && parsed['token']) {
          // 端点存在不代表引擎还活着：App 被 force-stop 时子进程会一起被杀，
          // 但旧端点文件还在。进程不在就必须重新启动，否则界面永远停在「正在连接」。
          const recordedPid = Number(parsed['pid'] ?? 0);
          let pidAlive = false;
          if (recordedPid > 0) {
            try {
              pidAlive = fs.accessSync(`/proc/${recordedPid}`);
            } catch (error) {
              pidAlive = false;
            }
          }
          if (pidAlive) {
            this.childPid = recordedPid;
            this.baseUrl = parsed['baseUrl'] as string;
            this.token = parsed['token'] as string;
            this.workspaceDir = this.dataRoot() + '/workspace';
            this.phase = 'running';
            this.error = null;
            return;
          }
          // 引擎已退出：清掉陈旧端点，让上层重新拉起。
          try {
            fs.unlinkSync(endpoint);
          } catch (error) { }
        }
      }
    } catch (error) {
      // 端点不可读时回落到安装状态。
    }
    this.phase = this.hasEngine() ? 'installed' : 'notInstalled';
  }

  private refreshRunning(): void {
    if (this.phase !== 'running') return;
    const endpoint = this.readEndpoint(this.endpointFile());
    let alive = false;
    try { alive = this.childPid > 0 && fs.accessSync(`/proc/${this.childPid}`); } catch (error) { }
    if (endpoint === null || endpoint['error'] || endpoint['stopped'] || !alive) {
      this.childPid = -1;
      this.baseUrl = null;
      this.token = null;
      this.phase = 'error';
      this.error = 'engine process exited';
      this.emit();
    }
  }

  private statusMap(): Map<string, Object> {
    const map: Map<string, Object> = new Map();
    map.set('phase', this.phase);
    if (this.baseUrl) map.set('baseUrl', this.baseUrl);
    if (this.token) map.set('token', this.token);
    if (this.workspaceDir) map.set('workspaceDir', this.workspaceDir);
    if (this.error) map.set('error', this.error);
    if (this.installedVersion) {
      map.set('installedVersion', this.installedVersion);
      map.set('bundledVersion', this.installedVersion);
    }
    map.set('mode', 'normal');
    map.set('safeState', 'off');
    map.set('strikes', 0);
    map.set('autoSafe', false);
    return map;
  }

  private async copyRawRuntime(): Promise<string> {
    const context = this.context as common.Context;
    const target = this.filesDir() + '/dsh-runtime.zip';
    // getRawFd 的 fd 指向整个 HAP，必须按 offset/length 取；直接整包内容更可靠。
    const content: Uint8Array = context.resourceManager.getRawFileContentSync('dsh-runtime.zip');
    if (content.byteLength < 1000000) {
      throw new Error(`raw archive too small: ${content.byteLength}`);
    }
    if (fs.accessSync(target)) fs.unlinkSync(target);
    const dest = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      const buffer = content.buffer.slice(content.byteOffset, content.byteOffset + content.byteLength);
      fs.writeSync(dest.fd, buffer);
    } finally {
      fs.closeSync(dest);
    }
    const size = fs.statSync(target).size;
    hilog.info(DOMAIN, TAG, `copied ${size} bytes of ${content.byteLength} to ${target}`);
    if (size !== content.byteLength) {
      throw new Error(`raw copy mismatch: ${size} != ${content.byteLength}`);
    }
    return target;
  }

  private async installRuntime(): Promise<void> {
    this.phase = 'installing';
    this.error = null;
    this.emit();
    hilog.info(DOMAIN, TAG, 'copying raw runtime zip');
    const zip = await this.copyRawRuntime();
    hilog.info(DOMAIN, TAG, `copied to ${zip}`);
    // 每次安装用全新目录，避免残留导致解压失败；成功后尽力清理旧目录。
    this.engineDir = this.filesDir() + '/engine-' + Date.now();
    const root = this.engineDir;
    fs.mkdirSync(root);
    hilog.info(DOMAIN, TAG, `install target ${root}`);
    hilog.info(DOMAIN, TAG, `decompress into ${root}`);
    await zlib.decompressFile(zip, root);
    hilog.info(DOMAIN, TAG, `decompress done hasEngine=${this.hasEngine()}`);
    if (!this.hasEngine()) {
      throw new Error('runtime archive missing dsh entry');
    }
    this.installedVersion = '0.2.1-rc.4';
    this.phase = 'installed';
    this.emit();
  }

  private async startEngine(): Promise<void> {
    if (this.stopPromise !== null) await this.stopPromise;
    const generation = ++this.generation;
    if (!this.hasEngine() || this.needsReinstall()) {
      hilog.info(DOMAIN, TAG, 'engine missing or stale before start, installing first');
      await this.installRuntime();
    }
    this.phase = 'starting';
    this.error = null;
    this.baseUrl = null;
    this.token = null;
    this.emit();

    const endpoint = this.endpointFile();
    if (fs.accessSync(endpoint)) fs.unlinkSync(endpoint);
    // 数据目录独立于安装版本，启停和升级保留会话及工作区。
    const data = this.dataRoot();
    if (!fs.accessSync(data)) fs.mkdirSync(data);

    // 引擎在独立进程的 EngineAbility（process: dsh_engine）里启动，
    // 避免 native child process 从带 FlutterEngine 的进程 fork 导致 Node 崩溃。
    const uiContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (!uiContext) {
      throw new Error('UIAbilityContext unavailable');
    }
    const want: Want = {
      bundleName: uiContext.abilityInfo.bundleName,
      abilityName: 'EngineAbility',
      parameters: {
        installedRoot: this.engineRoot(),
        endpointFile: endpoint,
        dataRoot: data,
        enablePrivateBroker: true
      }
    };
    await uiContext.startAbility(want);
    hilog.info(DOMAIN, TAG, 'EngineAbility start requested');

    // 轮询宿主私有端点；由宿主核对启动结果及退出回调，主桥不直接消费探针报告。
    const deadline = Date.now() + 90000;
    while (Date.now() < deadline) {
      await this.sleep(600);
      if (generation !== this.generation) return;
      if (!fs.accessSync(endpoint)) continue;
      const parsed = this.readEndpoint(endpoint);
      if (parsed === null) continue;
      if (parsed['error'] !== undefined) {
        hilog.error(DOMAIN, TAG, `engine reported ${parsed['error']}`);
        this.phase = 'error';
        this.error = parsed['error'] as string;
        this.emit();
        return;
      }
      if (!parsed['baseUrl'] || !parsed['token']) continue;
      this.childPid = Number(parsed['pid'] ?? -1);
      hilog.info(DOMAIN, TAG, 'engine reported a login line');
      this.baseUrl = parsed['baseUrl'] as string;
      this.token = parsed['token'] as string;
      this.workspaceDir = parsed['workspaceDir'] as string;
      this.phase = 'running';
      this.emit();
      return;
    }
    // 主桥的90秒期限先于宿主兜底期限；取消后必须等正式退出确认。
    // 不调用stopEngine，避免等待当前startPromise造成自等待。
    await this.requestStop();
    throw new Error('engine_start_timeout');
  }

  private readEndpoint(path: string): Record<string, Object> | null {
    try {
      const text = fs.readTextSync(path);
      const parsed = JSON.parse(text) as Record<string, Object>;
      return parsed;
    } catch (error) {
      return null;
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(() => resolve(), ms));
  }

  private async stopEngine(): Promise<void> {
    ++this.generation;
    if (this.startPromise !== null) await this.startPromise.catch(() => {});
    await this.requestStop();
  }

  private async requestStop(): Promise<void> {
    this.phase = 'stopping';
    this.emit();
    const uiContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
    if (!uiContext) throw new Error('UIAbilityContext unavailable');
    const endpoint = this.endpointFile();
    if (fs.accessSync(endpoint)) fs.unlinkSync(endpoint);
    await uiContext.startAbility({
      bundleName: uiContext.abilityInfo.bundleName, abilityName: 'EngineAbility',
      parameters: { action: 'stop', installedRoot: this.engineRoot(), endpointFile: endpoint, dataRoot: this.dataRoot() }
    } as Want);
    // 覆盖宿主等待spawn 10秒、broker回收15秒、主进程退出10秒，并留调度余量。
    const deadline = Date.now() + 45000;
    while (Date.now() < deadline) {
      await this.sleep(100);
      const value = this.readEndpoint(endpoint);
      if (value === null) continue;
      // 启动Promise尚未返回PID时，宿主仍负责回收迟到进程；继续等确认。
      if (value['error'] === 'spawn_pending') continue;
      if (value['error']) throw new Error(String(value['error']));
      if (value['stopped'] !== true) continue;
      fs.unlinkSync(endpoint);
      this.childPid = -1;
      this.baseUrl = null;
      this.token = null;
      this.phase = this.hasEngine() ? 'installed' : 'notInstalled';
      this.emit();
      return;
    }
    throw new Error('stop_confirmation_timeout');
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const name = call.method;
    hilog.info(DOMAIN, TAG, `method ${name}`);
    try {
      // 未实现的管理操作必须显式失败，不能让原界面误报已清理或已恢复。
      if (name === 'reset' || name === 'setAutoSafe' || name === 'setDirectEngine' ||
          name === 'restoreLastKnownGood' || name === 'safePreflight' || name === 'moveAside' ||
          name === 'requestBatteryExempt' || name === 'openBackgroundSettings' ||
          name === 'openVendorSettings' || name === 'openAllFilesAccess') {
        result.error('UNSUPPORTED', '鸿蒙暂不支持此运行环境管理操作', null);
        return;
      }
      if (name === 'start' && call.argument('mode') === 'safe') {
        result.error('UNSUPPORTED', '鸿蒙暂不支持安全模式启动', null);
        return;
      }
      if (name === 'getLogs') {
        result.success([]);
        return;
      }
      if (name === 'openAppSettings') {
        const uiContext = AppStorage.get<common.UIAbilityContext>('uiAbilityContext');
        if (!uiContext) {
          result.error('NO_CONTEXT', 'UIAbilityContext unavailable', null);
          return;
        }
        uiContext.startAbility({
          bundleName: 'com.huawei.hmos.settings',
          abilityName: 'com.huawei.hmos.settings.MainAbility',
          parameters: { 'settingsParam': 'application_info', 'bundleName': uiContext.abilityInfo.bundleName }
        } as Want).then(() => {
          result.success(true);
        }).catch((error: Error) => {
          result.error('OPEN_FAILED', `${error.message}`, null);
        });
        return;
      }
      if (name === 'getStatus') {
        this.refreshRunning();
        this.refreshInstalled();
        result.success(this.statusMap());
        return;
      }
      if (name === 'getStorageLayout') {
        const map: Map<string, Object> = new Map();
        map.set('version', 1);
        map.set('dataRoot', this.dataRoot());
        result.success(map);
        return;
      }
      if (name === 'install') {
        this.installRuntime().then(() => result.success(null)).catch((error: BusinessError) => {
          hilog.error(DOMAIN, TAG, `install rejected: ${error.code} ${error.message}`);
          this.phase = 'error';
          this.error = `install failed: ${error.message}`;
          this.emit();
          result.error('INSTALL_FAILED', this.error, null);
        });
        return;
      }
      if (name === 'start') {
        if (this.phase === 'running' && this.stopPromise === null) { result.success(null); return; }
        if (this.startPromise === null) this.startPromise = this.startEngine().finally(() => { this.startPromise = null; });
        this.startPromise.then(() => result.success(null)).catch((error: BusinessError) => {
          this.phase = 'error';
          this.error = `start failed: ${error.message}`;
          this.emit();
          result.error('START_FAILED', this.error, null);
        });
        return;
      }
      if (name === 'stop') {
        if (this.stopPromise === null) this.stopPromise = this.stopEngine().finally(() => { this.stopPromise = null; });
        this.stopPromise.then(() => result.success(null)).catch((error: Error) => {
          this.phase = 'error'; this.error = error.message; this.emit();
          result.error('STOP_FAILED', error.message, null);
        });
        return;
      }
      if (name === 'clearFailure') {
        this.error = null;
        this.emit();
        result.success(null);
        return;
      }
      if (name === 'lastKnownGood') {
        const map: Map<string, Object> = new Map();
        map.set('available', false);
        result.success(map);
        return;
      }
      if (name === 'networkMetered') {
        this.networkMetered().then((metered: boolean | null) => result.success(metered));
        return;
      }
      if (name === 'batteryExempt') {
        result.success(null);
        return;
      }
      if (name === 'installManagedSkill') {
        const map: Map<string, Object> = new Map();
        map.set('result', 'unsupported');
        map.set('current', false);
        result.success(map);
        return;
      }
      result.notImplemented();
    } catch (error) {
      const failure = error as BusinessError;
      hilog.error(DOMAIN, TAG, `failed ${name}: ${failure.code} ${failure.message}`);
      result.error('RUNTIME_FAILED', failure.message, null);
    }
  }

  private async networkMetered(): Promise<boolean | null> {
    try {
      // 没有默认网络时，系统的 false 不能证明存在非计费连接。
      if (!await connection.hasDefaultNet()) return null;
      return await connection.isDefaultNetMetered();
    } catch (_) {
      return null;
    }
  }
}
