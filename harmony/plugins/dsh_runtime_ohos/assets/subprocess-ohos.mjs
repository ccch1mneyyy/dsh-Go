import { Readable, Duplex } from 'node:stream';
import { isAbsolute } from 'node:path';

const WINDOW = 65536;
const MAX_FRAME = 1048576;
const SIGNALS = new Set(['SIGKILL', 'SIGTERM', 'SIGABRT', 'SIGSEGV', 'SIGBUS', 'SIGILL', 'SIGFPE', 'SIGSYS', 'SIGINT', 'SIGHUP', 'SIGPIPE']);
const failure = code => new Error(code);
const deferred = () => {
  const value = Promise.withResolvers();
  // 先于消费者安装监听的同步启动失败也不产生未处理拒绝。
  value.promise.catch(() => {});
  return value;
};

/** 用真实SubprocessRuntime基类注册；仅支持明确准入的一次性PTC入口。 */
export function createOhosSubprocessProvider(SubprocessRuntime, options) {
  const { transport, generation, executable, bootstrapPath, allowCwd } = options;
  if (!transport || typeof generation !== 'string' || !generation || !isAbsolute(executable) ||
      !isAbsolute(bootstrapPath) || typeof allowCwd !== 'function') throw failure('BROKER_CONFIGURATION');

  return class OhosSubprocessRuntime extends SubprocessRuntime {
    constructor(ctx) {
      super(ctx);
      this.tasks = new Map(); this.nextId = 1; this.closed = false;
      this.input = Buffer.alloc(0); this.output = []; this.outputBytes = 0; this.writing = false;
      this.onData = chunk => this.receiveBytes(chunk);
      this.onFailure = () => this.fail('BROKER_DISCONNECTED');
      transport.on('data', this.onData);
      transport.on('error', this.onFailure);
      transport.on('end', this.onFailure);
      transport.on('close', this.onFailure);
      ctx.effect(() => () => this.dispose(), 'ohos subprocess teardown');
    }
    async resolveExecutable(command, env, signal) {
      signal?.throwIfAborted();
      if (command !== executable && command !== 'node') throw failure('OHOS_EXECUTABLE_UNSUPPORTED');
      return executable;
    }
    send(id, type, fields = {}) {
      if (this.closed) throw failure('BROKER_DISCONNECTED');
      const bytes = Buffer.from(JSON.stringify({ v: 1, generation, id, type, ...fields }));
      if (!bytes.length || bytes.length > MAX_FRAME || this.outputBytes + bytes.length + 4 > MAX_FRAME * 2) {
        this.fail('BROKER_OUTPUT_LIMIT'); throw failure('BROKER_OUTPUT_LIMIT');
      }
      const frame = Buffer.allocUnsafe(bytes.length + 4);
      frame.writeUInt32BE(bytes.length); bytes.copy(frame, 4);
      this.output.push(frame); this.outputBytes += frame.length; this.flush();
    }
    flush() {
      if (this.writing || this.closed || !this.output.length) return;
      this.writing = true;
      const frame = this.output.shift();
      transport.write(frame, error => {
        this.writing = false; this.outputBytes -= frame.length;
        if (error) this.fail('BROKER_WRITE_FAILED'); else this.flush();
      });
    }
    receiveBytes(chunk) {
      if (this.closed) return;
      try {
        this.input = Buffer.concat([this.input, Buffer.from(chunk)]);
        while (this.input.length >= 4) {
          const size = this.input.readUInt32BE(0);
          if (!size || size > MAX_FRAME) throw failure('BROKER_FRAME_LIMIT');
          if (this.input.length < size + 4) break;
          const frame = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(this.input.subarray(4, size + 4)));
          this.input = this.input.subarray(size + 4);
          this.receive(frame);
        }
        if (this.input.length > MAX_FRAME + 4) throw failure('BROKER_FRAME_LIMIT');
      } catch (_) { this.fail('BROKER_PROTOCOL_FAILED'); }
    }
    receive(frame) {
      if (!frame || frame.v !== 1 || frame.generation !== generation || !Number.isSafeInteger(frame.id)) throw failure('BROKER_ID');
      const task = this.tasks.get(frame.id);
      if (!task) throw failure('BROKER_UNKNOWN_TASK');
      if (frame.type === 'spawnError') {
        if (task.spawned || frame.reaped !== true || typeof frame.code !== 'string' || !/^[A-Z0-9_]{1,80}$/.test(frame.code)) throw failure('BROKER_SPAWN_ERROR');
        task.done.reject(failure(frame.code)); task.reaped.resolve(); this.remove(task);
        for (const state of Object.values(task.streams)) state.stream.destroy();
        return;
      }
      if (frame.type === 'spawned') {
        if (task.spawned) throw failure('BROKER_DUPLICATE_SPAWN');
        task.spawned = true;
        for (const name of Object.keys(task.streams)) this.send(task.id, 'readCredit', { stream: name, bytes: WINDOW });
        if (task.stopping) this.send(task.id, 'stop');
        return;
      }
      if (!task.spawned) throw failure('BROKER_NOT_STARTED');
      if (frame.type === 'data') {
        const state = task.streams[frame.stream];
        if (!state || state.eof || typeof frame.data !== 'string') throw failure('BROKER_STREAM');
        const data = Buffer.from(frame.data, 'base64');
        if (!data.length || data.toString('base64') !== frame.data || data.length > state.credit) throw failure('BROKER_CREDIT');
        state.credit -= data.length; state.pending += data.length;
        if (!state.stream.destroyed) state.stream.push(data);
        // 已关闭控制端仍排空父端剩余输出，但不得无限保存字节。
        else this.credit(task, frame.stream);
        return;
      }
      if (frame.type === 'eof') {
        const state = task.streams[frame.stream];
        if (!state || state.eof) throw failure('BROKER_EOF');
        state.eof = true; if (!state.stream.destroyed) state.stream.push(null); return;
      }
      if (frame.type === 'writeAck') {
        if (!task.write || frame.seq !== task.write.seq) throw failure('BROKER_WRITE_ACK');
        const callback = task.write.callback; task.write = null; callback(); return;
      }
      if (frame.type === 'exit') {
        if (task.exitSeen || !Object.values(task.streams).every(state => state.eof)) throw failure('BROKER_EXIT_BEFORE_EOF');
        const normal = Number.isInteger(frame.exitCode) && frame.exitCode >= 0 && frame.exitCode <= 255 && frame.signal === null;
        const signalled = frame.exitCode === null && SIGNALS.has(frame.signal);
        if (!normal && !signalled) throw failure('BROKER_EXIT_STATUS');
        task.exitSeen = true; task.done.resolve({ exitCode: frame.exitCode, signal: frame.signal }); return;
      }
      if (frame.type === 'reaped') {
        if (!task.exitSeen) throw failure('BROKER_REAP_BEFORE_EXIT');
        task.reaped.resolve(); this.remove(task); return;
      }
      throw failure('BROKER_MESSAGE');
    }
    credit(task, name) {
      const state = task.streams[name];
      if (!this.tasks.has(task.id) || !task.spawned || state.eof || !state.pending || this.closed) return;
      // _read也会为填充缓冲触发；只补真正腾出的空间，不能把缓冲内字节当已消费。
      const buffered = state.stream.destroyed ? 0 : state.stream.readableLength;
      const bytes = Math.min(state.pending, WINDOW - buffered - state.credit);
      if (bytes <= 0) return;
      state.pending -= bytes; state.credit += bytes;
      this.send(task.id, 'readCredit', { stream: name, bytes });
    }
    stop(task) {
      if (task.stopping || !this.tasks.has(task.id)) return;
      task.stopping = true; this.send(task.id, 'stop');
    }
    remove(task) {
      this.tasks.delete(task.id); task.signal?.removeEventListener('abort', task.abort);
      if (task.write) { task.write.callback(failure('BROKER_TASK_EXITED')); task.write = null; }
    }
    spawn(spec) {
      if (this.closed) throw failure('BROKER_DISCONNECTED');
      const argv = spec.argv;
      if (!Array.isArray(argv) || argv.length !== 4 || argv[0] !== executable ||
          !/^--max-old-space-size=[1-9][0-9]{0,4}$/.test(argv[1]) || argv[2] !== bootstrapPath ||
          !/^[1-9][0-9]*$/.test(argv[3]) || Number(argv[3]) > 4294967295 ||
          !isAbsolute(spec.cwd) || allowCwd(spec.cwd) !== true ||
          spec.stdio?.stdin !== 'ignore' || spec.stdio?.stdout !== 'pipe' ||
          spec.stdio?.stderr !== 'pipe' || spec.stdio?.control !== 'pipe' ||
          !Number.isInteger(spec.graceMs) || spec.graceMs < 0 || spec.graceMs > 30000) throw failure('OHOS_SPAWN_UNSUPPORTED');
      const envSet = Object.create(null), envUnset = [];
      for (const [key, value] of Object.entries(spec.env ?? {})) {
        if (!key || key.includes('=') || key.includes('\0')) throw failure('OHOS_ENV_INVALID');
        if (value === undefined) envUnset.push(key);
        else if (typeof value === 'string' && !value.includes('\0')) envSet[key] = value;
        else throw failure('OHOS_ENV_INVALID');
      }
      const task = { id: this.nextId++, spawned: false, stopping: false, exitSeen: false,
        done: deferred(), reaped: deferred(), streams: Object.create(null), seq: 0, write: null,
        signal: spec.signal, abort: null, ended: false };
      const provider = this;
      for (const name of ['stdout', 'stderr', 'control']) {
        const state = { stream: null, credit: WINDOW, pending: 0, eof: false };
        const config = { highWaterMark: WINDOW, read() {
          // Readable.read先调用_read，再从缓冲取出数据；本轮结束后核算实际剩余量。
          queueMicrotask(() => provider.credit(task, name));
        } };
        if (name === 'control') {
          config.write = (chunk, encoding, callback) => {
            const data = Buffer.from(chunk); let offset = 0;
            const part = error => {
              if (error) { callback(error); return; }
              if (offset === data.length) { callback(); return; }
              const bytes = data.subarray(offset, offset + WINDOW); offset += bytes.length;
              const seq = ++task.seq; task.write = { seq, callback: part };
              try { provider.send(task.id, 'write', { seq, data: bytes.toString('base64') }); }
              catch (error) { task.write = null; callback(error); }
            };
            part();
          };
          config.final = callback => { try { if (!task.ended && provider.tasks.has(task.id)) provider.send(task.id, 'end'); task.ended = true; callback(); } catch (error) { callback(error); } };
          config.destroy = (error, callback) => {
            try { if (!task.ended && provider.tasks.has(task.id) && !provider.closed) provider.send(task.id, 'end'); task.ended = true; } catch (_) { }
            callback(error);
          };
          state.stream = new Duplex(config);
        } else state.stream = new Readable(config);
        // 错误仍传给消费者监听器；启动早期不产生未处理error事件。
        state.stream.on('error', () => {}); task.streams[name] = state;
      }
      this.tasks.set(task.id, task);
      task.abort = () => this.stop(task);
      this.send(task.id, 'spawn', { spec: { kind: 'ptc-oneshot', argv: [...argv], cwd: spec.cwd,
        envSet, envUnset, stdio: { ...spec.stdio }, graceMs: spec.graceMs } });
      spec.signal?.addEventListener('abort', task.abort, { once: true });
      if (spec.signal?.aborted) task.abort();
      return { stdin: null, stdout: task.streams.stdout.stream, stderr: task.streams.stderr.stream,
        control: task.streams.control.stream, done: task.done.promise,
        terminate: () => this.stop(task), waitForExit: () => task.reaped.promise };
    }
    async dispose() {
      const tasks = [...this.tasks.values()];
      for (const task of tasks) this.stop(task);
      await Promise.all(tasks.map(task => task.reaped.promise));
      this.closed = true;
      transport.off('data', this.onData); transport.off('error', this.onFailure);
      transport.off('end', this.onFailure); transport.off('close', this.onFailure);
      transport.destroy();
    }
    fail(code) {
      if (this.closed) return;
      this.closed = true;
      for (const task of this.tasks.values()) {
        const error = failure(code); task.done.reject(error); task.reaped.reject(error);
        if (task.write) { task.write.callback(error); task.write = null; }
        for (const state of Object.values(task.streams)) state.stream.destroy(error);
        task.signal?.removeEventListener('abort', task.abort);
      }
      this.tasks.clear(); this.output = []; transport.destroy();
    }
    // 仅用于主代码装配；实际隔离仍由宿主原生任务强制。
    get ohosIsolatedPtc() { return true; }
    spawnTerminal() { throw failure('OHOS_TERMINAL_UNSUPPORTED'); }
  };
}
