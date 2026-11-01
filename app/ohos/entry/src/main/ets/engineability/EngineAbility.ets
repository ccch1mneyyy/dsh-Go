import broker from 'libdsh_broker.so';
import { HarmonyBrokerHost } from './HarmonyBrokerHost';
import { HarmonyTaskDriver } from './HarmonyTaskDriver';
import { SpawnSpec } from './broker/parent-broker.js';

import control from 'libdsh_control.so';
import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import childProcessManager from '@ohos.app.ability.childProcessManager';
import { ChildProcessArgs } from '@ohos.app.ability.ChildProcessArgs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';


const TAG = 'DshEngineAbility';
const DOMAIN = 0x0002;

/**
 * 独立进程里的引擎宿主（process: :dsh_engine）。
 * 加载一个空白页面后立刻隐藏窗口，让 Ability 保持存活而不打扰用户；
 * 在该进程里启动 native child process，避免从带 FlutterEngine 的进程 fork。
 */
export default class EngineAbility extends UIAbility {
  private childPid: number = -1;
  private starting: boolean = false;
  private timer: number = -1;
  private generation: number = 0;
  private stopping: boolean = false;
  private brokerHost: HarmonyBrokerHost | undefined = undefined;
  private brokerHandle: number = -1;
  private windowReady: boolean = false;

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Engine', (error) => {
      if (error && error.code) {
        hilog.error(DOMAIN, TAG, `loadContent failed ${error.code}`);
        return;
      }
      // 引擎宿主页建立后回到原主界面，避免最小化整个应用任务。
      this.windowReady = true;
      this.returnToMain();
    });
  }

  onCreate(want: Want, launchParam: object): void {
    this.handleWant(want);
  }

  onNewWant(want: Want, launchParam: object): void {
    this.handleWant(want);
  }

  onForeground(): void {
    // 新Want之后框架才前置宿主，必须在此时恢复原页面。
    if (this.windowReady) this.returnToMain();
  }

  private returnToMain(): void {
    // 恢复已有Flutter页面，不改变引擎启动、停止或失败的确认结果。
    this.context.startAbility({
      bundleName: this.context.abilityInfo.bundleName,
      abilityName: 'EntryAbility'
    }).catch(() => { hilog.error(DOMAIN, TAG, '主界面恢复失败'); });
  }

  private handleWant(want: Want): void {
    const params = want.parameters ?? {};
    const installedRoot = params['installedRoot'] as string;
    const endpointFile = params['endpointFile'] as string;
    const dataRoot = params['dataRoot'] as string;
    hilog.info(DOMAIN, TAG, '收到引擎生命周期请求');
    if (!installedRoot || !endpointFile || !dataRoot) {
      hilog.error(DOMAIN, TAG, 'missing parameters');
      return;
    }
    if (params['action'] === 'stop') { this.stop(endpointFile); return; }
    if (this.stopping || this.starting || this.brokerHandle > 0 || (this.childPid > 0 && !control.exited(this.childPid))) return;
    this.launch(installedRoot, endpointFile, dataRoot, params['enablePrivateBroker'] === true);
  }

  private launch(installedRoot: string, endpointFile: string, dataRoot: string, enablePrivateBroker: boolean = false): void {
    this.starting = true;
    const generation = ++this.generation;
    // 只回收本宿主已确认退出的主引擎记录，不清除兄弟任务回调。
    if (this.childPid > 0 && control.exited(this.childPid)) control.forget(this.childPid);
    this.childPid = -1;
    if (control.watch() !== 0) { this.starting = false; this.writeEndpoint(endpointFile, JSON.stringify({ error: 'exit_watch_failed' })); return; }
    try {
      if (fs.accessSync(endpointFile)) {
        fs.unlinkSync(endpointFile);
      }
    } catch (error) {
      // 端点文件不存在时忽略。
    }
    // 探针宿主直接写 reports/<phase>/，目录必须先存在，否则报告与端点全部丢失。
    try {
      fs.mkdirSync(`${installedRoot}/reports/dsh`, true);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'mkdir reports failed');
    }
    const reportPath = `${installedRoot}/reports/dsh/result.json`;
    try {
      if (fs.accessSync(reportPath)) fs.unlinkSync(reportPath);
    } catch (error) {
      // 旧报告不存在时忽略。
    }
    // 启动阶段不读取或注入模型凭据；连接后由原版设置同步。
    const args: ChildProcessArgs = {
      entryParams: `dsh|${installedRoot}|${dataRoot}`
    };
    let connectionHandle = -1;
    if (enablePrivateBroker) {
      try {
        const connection = broker.create();
        if (connection.error !== 0 || connection.handle === undefined || connection.fd === undefined) throw new Error('BROKER_CREATE_FAILED');
        connectionHandle = connection.handle; this.brokerHandle = connectionHandle;
        const wireGeneration = 'engine-' + generation + '-' + Date.now();
        const bootstrap = installedRoot + '/opt/dsh/node_modules/@deepseek-ai/dsh-ptc-runtime-node/lib/process.js';
        const driver = new HarmonyTaskDriver(installedRoot, '/ohos/node', bootstrap);
        this.brokerHost = new HarmonyBrokerHost(connectionHandle, wireGeneration, driver, (spec: SpawnSpec): boolean => driver.accepts(spec));
        args.entryParams += '|' + wireGeneration;
        args.fds = { dshBroker: connection.fd };
        this.brokerHost.start();
      } catch (_) {
        this.starting = false;
        void this.stop(endpointFile, 'broker_setup_failed');
        return;
      }
    }
    childProcessManager.startNativeChildProcess('libdsh_runtime.so:ProbeDsh', args)
      .then((pid: number) => {
        this.starting = false;
        this.childPid = pid;
        if (connectionHandle > 0 && broker.attached(connectionHandle) !== 0) {
          void this.stop(endpointFile, 'broker_attach_failed'); return;
        }
        if (generation !== this.generation) {
          // 停止等待已超时时，迟到的进程仍归本宿主回收。
          if (!this.stopping) void this.stop(endpointFile);
          return;
        }
        hilog.info(DOMAIN, TAG, `engine child started pid=${pid}`);
        this.watchReport(reportPath, endpointFile, dataRoot, installedRoot);
      })
      .catch(() => {
        this.starting = false;
        if (generation !== this.generation) { if (!this.stopping) void this.stop(endpointFile); return; }
        hilog.error(DOMAIN, TAG, '引擎子进程启动失败');
        void this.stop(endpointFile, 'spawn_failed');
      });
  }

  /** 把探针脚本写出的安全报告转成 Flutter 侧约定的 endpoint 文件。 */
  private watchReport(reportPath: string, endpointFile: string, dataRoot: string, installedRoot: string): void {
    let ticks = 0;
    let ready = false;
    const generation = this.generation;
    const timer = setInterval(() => {
      if (generation !== this.generation) { clearInterval(timer); return; }
      if (control.exited(this.childPid)) {
        clearInterval(timer);
        void this.stop(endpointFile, this.reportFailure(reportPath) ?? 'engine_exited');
        return;
      }
      if (ready) return;
      ticks += 1;
      if (ticks > 300) {
        clearInterval(timer);
        void this.stop(endpointFile, 'engine_timeout');
        return;
      }
      if (!fs.accessSync(reportPath)) return;
      try {
        const value = JSON.parse(fs.readTextSync(reportPath)) as Record<string, string>;
        if (value['base_url'] && value['access_token']) {
          ready = true;
          this.writeEndpoint(endpointFile, JSON.stringify({
            baseUrl: value['base_url'],
            token: value['access_token'],
            port: 38081,
            workspaceDir: dataRoot + '/workspace',
            pid: this.childPid,
            startedAt: Date.now(),
          }));
          return;
        }
        if (value['phase'] === 'FAILED' || value['phase'] === 'PREFLIGHT_FAILED') {
          clearInterval(timer);
          void this.stop(endpointFile, this.reportFailure(reportPath) ?? 'engine_failed');
        }
      } catch (error) {
        // 报告正在写入时忽略，下一轮再读。
      }
    }, 800);
    this.timer = timer;
  }

  private reportFailure(reportPath: string): string | null {
    try {
      const value = JSON.parse(fs.readTextSync(reportPath)) as Record<string, string>;
      if (value['phase'] !== 'FAILED' && value['phase'] !== 'PREFLIGHT_FAILED') return null;
      const code = value['code'];
      // 仅转发固定格式错误码，不透传异常正文、日志或凭据。
      return typeof code === 'string' && /^[A-Z0-9_]{1,80}$/.test(code) ? code : 'ENGINE_FAILED';
    } catch (error) {
      return null;
    }
  }

  private async stop(endpointFile: string, failure: string | null = null): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;
    ++this.generation;
    try {
    clearInterval(this.timer);
    const spawnDeadline = Date.now() + 10000;
    while (this.starting && Date.now() < spawnDeadline) await new Promise<void>((resolve) => setTimeout(resolve, 50));
    if (this.starting) { this.writeEndpoint(endpointFile, JSON.stringify({ error: 'spawn_pending' })); return; }
    // 待启动调用返回之前不能关闭可能尚在移交的FD；迟到PID到达会再次进入stop。
    const pid = this.childPid;
    let brokerClean = true;
    try { await this.shutdownBroker(); } catch (_) { brokerClean = false; }
    if (pid > 0 && !control.exited(pid)) {
      const code = control.stop(pid);
      if (code !== 0) { this.writeEndpoint(endpointFile, JSON.stringify({ error: 'stop_failed_' + code })); return; }
      const deadline = Date.now() + 10000;
      while (!control.exited(pid) && Date.now() < deadline) await new Promise<void>((resolve) => setTimeout(resolve, 50));
      if (!control.exited(pid)) { this.writeEndpoint(endpointFile, JSON.stringify({ error: 'stop_timeout' })); return; }
    }
    clearInterval(this.timer);
    if (pid > 0) control.forget(pid);
    this.childPid = -1;
    if (!brokerClean) { this.writeEndpoint(endpointFile, JSON.stringify({ error: 'broker_cleanup_failed' })); return; }
    this.writeEndpoint(endpointFile, JSON.stringify(failure ? { error: failure } : { stopped: true }));
    } finally { this.stopping = false; }
  }

  private async shutdownBroker(): Promise<void> {
    if (this.brokerHost !== undefined) await this.brokerHost.shutdown();
    else if (this.brokerHandle > 0 && broker.close(this.brokerHandle) !== 0) throw new Error('BROKER_CLOSE_FAILED');
    this.brokerHost = undefined; this.brokerHandle = -1;
  }

  private writeEndpoint(path: string, payload: string): void {
    try {
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, payload);
      fs.closeSync(file);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'write endpoint failed');
    }
  }
}
