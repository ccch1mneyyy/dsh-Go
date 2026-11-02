import { Worker } from 'node:worker_threads';
import { ImageFailure } from './container.mjs';
// CRC/熵段扫描也离开无JIT主线程；每实例最多两个在途输入，空闲worker不阻止退出。
export function createHeaderReader() {
  let worker, serial = 0, closed = false; const pending = new Map();
  function failed(owner) {
    if (worker !== owner) return;
    for (const task of pending.values()) task.reject(new ImageFailure('IMAGE_BACKEND_FAILED'));
    pending.clear(); worker = undefined;
  }
  function request(bytes, operation, mediaType) {
      if (closed) return Promise.reject(new ImageFailure('IMAGE_BACKEND_CLOSED'));
      if (!bytes?.byteLength || bytes.byteLength > (operation === 'clean-encoded' ? 33554432 : 20971520)) return Promise.reject(new ImageFailure('INVALID_IMAGE'));
      if (pending.size >= 2) return Promise.reject(new ImageFailure('IMAGE_BACKEND_BUSY'));
      if (!worker) {
        worker = new Worker(new URL('./container-worker.mjs', import.meta.url), { env: {}, execArgv: [] });
        const owner = worker;
        owner.on('message', ({ id, info, errorCode }) => {
          if (worker !== owner) return;
          const task = pending.get(id); if (!task) return; pending.delete(id);
          if (errorCode) task.reject(new ImageFailure(errorCode)); else task.resolve(info);
          if (!pending.size) worker?.unref();
        });
        owner.on('error', () => failed(owner)); owner.on('exit', () => failed(owner));
      }
      worker.ref(); const id = ++serial;
      const task = Promise.withResolvers(); pending.set(id, task);
      try { worker.postMessage({ id, operation, mediaType, bytes: Buffer.from(bytes) }); }
      catch { pending.delete(id); if (!pending.size) worker.unref(); task.reject(new ImageFailure('IMAGE_BACKEND_FAILED')); }
      return task.promise;
  }
  return {
    read(bytes) { return request(bytes, 'inspect'); },
    async cleanEncoded(bytes, mediaType) {
      const result = await request(bytes, 'clean-encoded', mediaType);
      return { data: Buffer.from(result.data.buffer, result.data.byteOffset, result.data.byteLength), removed: result.removed };
    },
    async close() {
      closed = true;
      // 先等当前解析任务settle；不以terminate伪装取消已完成。
      await Promise.allSettled([...pending.values()].map(task => task.promise));
      const current = worker; worker = undefined; if (current) await current.terminate();
    }
  };
}
