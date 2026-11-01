import { lstatSync, unlinkSync } from 'node:fs';
import * as promises from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { dirname, isAbsolute, join, resolve } from 'node:path';

const linkFallbackCodes = new Set(['EACCES', 'EPERM', 'EXDEV', 'ENOTSUP', 'EMLINK']);
const identityOf = info => ({ dev: String(info.dev), ino: String(info.ino) });
const sameIdentity = (info, receipt) => String(info.dev) === receipt.dev && String(info.ino) === receipt.ino;
const requirePath = (path, label) => {
  if (typeof path !== 'string' || !isAbsolute(path) || path.includes('\0')) {
    throw new TypeError(`${label} must be an absolute path without NUL`);
  }
  return resolve(path);
};

/**
 * Remove only one explicitly owned temporary entry. A receipt is a trusted
 * caller record, not proof obtainable by scanning a filename prefix.
 * The identity check and unlink share one JS turn. This assumes the application
 * owns this private directory; it is not an atomic compare-inode-and-unlink
 * operation against arbitrary concurrent native/foreign writers.
 */
export function cleanupOwnedTemporary(receipt) {
  requirePath(receipt.path, 'temporary path');
  let info;
  try { info = lstatSync(receipt.path, { bigint: true }); }
  catch (error) {
    if (error.code === 'ENOENT') return { removed: false, absent: true };
    throw error;
  }
  if (!info.isFile() || !sameIdentity(info, receipt)) {
    throw Object.assign(new Error('Owned publication temporary was replaced; refusing to unlink it'),
      { code: 'ERR_OHOS_PUBLICATION_TEMP_REPLACED' });
  }
  unlinkSync(receipt.path);
  return { removed: true, absent: false };
}

async function allocateTemporary({ parent, source, target, fs }) {
  for (let attempt = 0; attempt < 32; attempt++) {
    const path = join(parent, `.dsh-ohos-publish-${randomUUID()}.tmp`);
    if (path === source || path === target) continue;
    try { return { path, handle: await fs.open(path, 'wx', 0o600) }; }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  throw Object.assign(new Error('Could not allocate an exclusive publication temporary'),
    { code: 'ERR_OHOS_PUBLICATION_TEMP_COLLISION' });
}

async function copyStream(input, output, signal) {
  const buffer = Buffer.allocUnsafe(65536);
  for (;;) {
    signal?.throwIfAborted();
    const { bytesRead } = await input.read(buffer, 0, buffer.length, null);
    if (bytesRead === 0) break;
    await output.writeFile(buffer.subarray(0, bytesRead));
  }
  signal?.throwIfAborted();
  await output.sync();
}

// This is deliberately the existing risky fallback: a partial final file may
// remain after failure/SIGKILL. It is used only for the native commit's EINVAL.
async function legacyExclusiveCopy(source, target, fs, signal) {
  const input = await fs.open(source, 'r');
  try {
    const output = await fs.open(target, 'wx', 0o600);
    try { await copyStream(input, output, signal); }
    finally { await output.close(); }
  } finally { await input.close(); }
}

/**
 * Build a publisher for one main Node engine. The native function must invoke
 * renameat2(..., RENAME_NOREPLACE), synchronously returning undefined or throwing
 * a system error. No plain rename/copy is a native fallback.
 *
 * registerTemporary runs after identity acquisition and before the first copy
 * write. Persisting that record enables recovery for the recorded interval;
 * a crash between file creation and registration remains explicitly outside
 * automatic recovery. Unknown files must be preserved.
 */
export function createAtomicPublisher({
  renameNoReplace,
  fs = promises,
  createTemporary = allocateTemporary,
  registerTemporary = async () => {},
  onFallback = () => {},
} = {}) {
  if (typeof renameNoReplace !== 'function') throw new TypeError('renameNoReplace is required');
  const publications = new Map();
  const publish = async function publish(source, target, { signal, fs: callFs } = {}) {
    source = requirePath(source, 'source');
    target = requirePath(target, 'target');
    const activeFs = callFs ? { ...fs, ...callFs } : fs;
    const previous = publications.get(target);
    const completed = Promise.withResolvers();
    publications.set(target, completed.promise);
    if (previous) await previous;
    let input, output, receipt, method, failure;
    try {
      signal?.throwIfAborted();
      try {
        await activeFs.link(source, target);
        return { method: 'link' };
      } catch (error) {
        if (!linkFallbackCodes.has(error?.code)) throw error;
      }
      input = await activeFs.open(source, 'r');
      const temporary = await createTemporary({ parent: dirname(target), source, target, fs: activeFs });
      output = temporary.handle;
      const path = requirePath(temporary.path, 'temporary');
      if (dirname(path) !== dirname(target) || path === target || path === source) {
        throw new Error('Publication temporary must be a distinct entry in the final target directory');
      }
      const info = await output.stat({ bigint: true });
      if (!info.isFile()) throw new Error('Publication temporary must be a regular file');
      if (BigInt(info.size) !== 0n) throw new Error('Publication temporary must be newly allocated and empty');
      receipt = { path, ...identityOf(info) };
      await registerTemporary(Object.freeze({ ...receipt }));
      await copyStream(input, output, signal);
      signal?.throwIfAborted();
      // No await separates the same-Node ownership check and synchronous commit.
      const current = lstatSync(path, { bigint: true });
      if (!current.isFile() || !sameIdentity(current, receipt)) {
        throw Object.assign(new Error('Publication temporary changed before atomic commit'),
          { code: 'ERR_OHOS_PUBLICATION_TEMP_REPLACED' });
      }
      try {
        const result = renameNoReplace(path, target);
        if (result !== undefined) throw new TypeError('renameNoReplace must be synchronous and return undefined');
        method = 'rename-noreplace';
      } catch (error) {
        // File write/sync/close errors, EEXIST, EXDEV, EACCES and ENOSYS never
        // enter this branch merely because they happened during publication.
        if (error?.code !== 'EINVAL' || error?.syscall !== 'renameat2') throw error;
        await onFallback({ code: error.code, syscall: error.syscall,
          risk: 'partial final file remains possible after failure or process death' });
        await legacyExclusiveCopy(source, target, activeFs, signal);
        method = 'exclusive-copy-fallback';
      }
    } catch (error) { failure = error; }
    finally {
      const failures = failure === undefined ? [] : [failure];
      for (const handle of [output, input]) if (handle) {
        try { await handle.close(); } catch (error) { failures.push(error); }
      }
      if (receipt) {
        try { cleanupOwnedTemporary(receipt); } catch (error) { failures.push(error); }
      }
      completed.resolve();
      if (publications.get(target) === completed.promise) publications.delete(target);
      if (failures.length === 1) throw failures[0];
      if (failures.length > 1) throw new AggregateError(failures, 'Publication failed and cleanup reported an additional error', { cause: failures[0] });
    }
    return { method };
  };
  return Object.defineProperty(publish, 'pendingCount', { get: () => publications.size });
}
