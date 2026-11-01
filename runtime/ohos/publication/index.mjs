import { isMainThread } from 'node:worker_threads';
import { createAtomicPublisher } from './atomic.mjs';

export const publicationSymbol = Symbol.for('dsh.go.ohos.publication');
const simulationSymbol = Symbol.for('dsh.go.ohos.sim');

export function installPublication() {
  if (process.platform !== 'openharmony' && globalThis[simulationSymbol] !== true) {
    return { installed: false, reason: 'not-openharmony' };
  }
  // Worker startup inherits --import arguments. This service belongs to the
  // single main engine; unrelated virtual shell workers must remain startable.
  if (!isMainThread) return { installed: false, reason: 'not-main-thread' };
  if (process.versions.node !== '24.22.1') {
    throw Object.assign(new Error('OpenHarmony publication requires Node 24.22.1'),
      { code: 'ERR_OHOS_PUBLICATION_NODE_VERSION' });
  }
  if (Object.hasOwn(globalThis, publicationSymbol)) {
    throw Object.assign(new Error('OpenHarmony publication service is already registered'),
      { code: 'ERR_OHOS_PUBLICATION_DUPLICATE' });
  }
  let binding;
  try { binding = process._linkedBinding('dsh_ohos_publication'); }
  catch (cause) {
    throw Object.assign(new Error('OpenHarmony publication linked binding is unavailable', { cause }),
      { code: 'ERR_OHOS_PUBLICATION_BINDING_MISSING' });
  }
  if (typeof binding.renameNoReplace !== 'function') {
    throw Object.assign(new Error('OpenHarmony publication binding lacks renameNoReplace'),
      { code: 'ERR_OHOS_PUBLICATION_BINDING_INVALID' });
  }
  let fallbackWarningIssued = false;
  const publish = createAtomicPublisher({
    renameNoReplace: binding.renameNoReplace,
    onFallback() {
      if (fallbackWarningIssued) return;
      fallbackWarningIssued = true;
      process.emitWarning('renameat2(RENAME_NOREPLACE) returned EINVAL. OpenHarmony publication is using exclusive copy; a partial final file can remain after failure or process death.',
        { code: 'OHOS_PUBLICATION_NONATOMIC_FALLBACK' });
    },
  });
  const service = Object.freeze({
    protocolVersion: 1,
    recovery: 'current-invocation-only; unregistered crash orphans are preserved',
    get pendingCount() { return publish.pendingCount; },
    publish,
  });
  Object.defineProperty(globalThis, publicationSymbol, { value: service });
  return { installed: true, protocolVersion: service.protocolVersion };
}
