import nodeVersion from '../node-version.json' with { type: 'json' };
import { isMainThread } from 'node:worker_threads';
import { link, open, realpath, stat } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { isAbsolute, join, parse } from 'node:path';
import { createAtomicPublisher } from './atomic.mjs';
import { openOwnershipLedger } from './ledger.mjs';
import { openAtomicFuse, readSystemBuildIdentity } from './atomic-fuse.mjs';

export const publicationSymbol = Symbol.for('dsh.go.ohos.publication');
const simulationSymbol = Symbol.for('dsh.go.ohos.sim');
let installing = false;
let installedOwnership;

// Borrow the one already-open main-engine ledger. A subprocess job must not
// acquire a second flock, close this process-wide owner, or use the publication
// state slot for unrelated Git data. Workers receive only a job-bound RPC.
export function borrowInstalledOwnership() {
  if (!isMainThread) {
    throw Object.assign(new Error('Ownership resources belong to the main engine'),
      { code: 'ERR_OHOS_OWNERSHIP_MAIN_THREAD' });
  }
  if (!installedOwnership) {
    throw Object.assign(new Error('The main-engine ownership service is unavailable'),
      { code: 'ERR_OHOS_OWNERSHIP_UNAVAILABLE' });
  }
  return installedOwnership;
}

// Some OpenHarmony builds reject renameat2, flock, xattr or hard links inside
// the app-data filesystem. The atomic core already falls back to an exclusive
// copy for a proven EINVAL; this is the outer guard for any other native
// capability failure so an attachment upload can still be published. It keeps
// the same no-clobber contract: link first, then an exclusive ('wx') copy, and
// never removes or replaces an existing target.
const fallbackPublications = new Map();
const fallbackLinkCodes = new Set([
  'EACCES', 'EPERM', 'EXDEV', 'ENOTSUP', 'EOPNOTSUPP', 'ENOSYS',
  'EINVAL', 'EMLINK', 'EROFS', 'ENOTDIR',
]);
export async function exclusiveCopyFallback(source, target, fs = { link, open }) {
  const probe = globalThis[Symbol.for('dsh.go.ohos.linkProbe')];
  const previous = fallbackPublications.get(target);
  let release;
  const completed = new Promise(resolve => { release = resolve; });
  fallbackPublications.set(target, completed);
  if (previous) await previous;
  try {
    try {
      await fs.link(source, target);
      probe?.('publication.publish', { target, method: 'link-fallback', ok: true });
      return { method: 'link-fallback' };
    } catch (error) {
      probe?.('publication.link', { target, code: error?.code ?? null, message: error?.message ?? null });
      // EEXIST is a benign publication race: the target already holds the exact
      // bytes (the caller verifies its digest). Never overwrite it.
      if (error?.code === 'EEXIST') throw error;
      if (!fallbackLinkCodes.has(error?.code)) throw error;
    }
    const input = await fs.open(source, 'r');
    try {
      const output = await fs.open(target, 'wx', 0o600);
      try {
        const buffer = Buffer.allocUnsafe(65536);
        for (;;) {
          const { bytesRead } = await input.read(buffer, 0, buffer.length, null);
          if (bytesRead === 0) break;
          await output.writeFile(buffer.subarray(0, bytesRead));
        }
        // Directory/file fsync is not available on every OHOS app-data view.
        // The copy is already durable enough for the upload path; a rejected
        // sync must not turn a successful write into a failed attachment.
        try { await output.sync(); }
        catch (error) { probe?.('publication.sync', { target, code: error?.code ?? null, ignored: true }); }
      } finally { await output.close(); }
    } finally { await input.close(); }
    probe?.('publication.publish', { target, method: 'exclusive-copy-fallback', ok: true });
    return { method: 'exclusive-copy-fallback' };
  } catch (error) {
    probe?.('publication.publish', { target, ok: false, code: error?.code ?? null, message: error?.message ?? null });
    throw error;
  } finally {
    release();
    if (fallbackPublications.get(target) === completed) fallbackPublications.delete(target);
  }
}

// The attachment store reaches publication through
// globalThis[Symbol.for('dsh.go.ohos.publication')] and rejects the upload
// with ATTACHMENT_WRITE_FAILED when that service is absent. The native
// installPublication() has many preconditions (exact Node version, a linked
// binding with five operations, a valid DSH_HOME, a recoverable ownership
// ledger, renameat2 support); on some OpenHarmony builds one of them fails
// and the whole atomic service is never registered. Register a pure-JS
// fallback with the same protocolVersion/publish contract in that case so an
// attachment can still be published. `publish` reuses exclusiveCopyFallback,
// i.e. an exclusive, no-clobber link-then-'wx'-copy that needs no native
// capability. This covers the whole "publication service missing" failure
// class; when the native service is present we never replace it.
export function installFallbackPublication(reason, warn = true) {
  const existing = globalThis[publicationSymbol];
  if (existing?.protocolVersion === 1 && typeof existing.publish === 'function') {
    return { installed: false, reason: 'native-service-present' };
  }
  const service = Object.freeze({
    protocolVersion: 1,
    atomic: 'unsupported',
    systemVersion: undefined,
    get pendingCount() { return fallbackPublications.size; },
    publish(source, target, options = {}) {
      return exclusiveCopyFallback(source, target, options?.fs);
    },
    publishAtomic(source, target, options = {}) {
      // No durable ledger is available in fallback mode; keep the exclusive
      // no-clobber contract rather than pretending atomicity.
      return exclusiveCopyFallback(source, target, options?.fs);
    },
  });
  try {
    Object.defineProperty(globalThis, publicationSymbol, {
      value: service, configurable: false, enumerable: false, writable: false,
    });
  } catch (cause) {
    // A non-configurable placeholder must not abort engine startup. Report it
    // and let the existing service (if any) stand; publishOhosExclusive will
    // validate it on first use.
    if (warn) process.emitWarning(
      `OpenHarmony publication fallback could not register: ${cause?.message ?? cause}`,
      { code: 'OHOS_PUBLICATION_FALLBACK_REGISTER_FAILED' });
    return { installed: false, reason: 'register-failed' };
  }
  if (warn) {
    process.emitWarning(
      `OpenHarmony native publication unavailable (${String(reason?.code ?? reason?.message ?? reason)}); ` +
      'using pure-JS exclusive-copy publication for attachments.',
      { code: 'OHOS_PUBLICATION_PURE_JS_FALLBACK' });
  }
  return { installed: true, fallback: true, protocolVersion: 1 };
}

export async function installPublication() {
  if (process.platform !== 'openharmony' && globalThis[simulationSymbol] !== true) {
    return { installed: false, reason: 'not-openharmony' };
  }
  // Worker startup inherits --import arguments. This service belongs to the
  // single main engine; unrelated virtual shell workers must remain startable.
  if (!isMainThread) return { installed: false, reason: 'not-main-thread' };
  if (process.versions.node !== nodeVersion) {
    throw Object.assign(new Error(`OpenHarmony publication requires Node ${nodeVersion}`),
      { code: 'ERR_OHOS_PUBLICATION_NODE_VERSION' });
  }
  if (installing || Object.hasOwn(globalThis, publicationSymbol)) {
    throw Object.assign(new Error('OpenHarmony publication service is already registered'),
      { code: 'ERR_OHOS_PUBLICATION_DUPLICATE' });
  }
  let binding;
  try { binding = process._linkedBinding('dsh_ohos_publication'); }
  catch (cause) {
    throw Object.assign(new Error('OpenHarmony publication linked binding is unavailable', { cause }),
      { code: 'ERR_OHOS_PUBLICATION_BINDING_MISSING' });
  }
  const required = ['renameNoReplace', 'lockExclusive', 'setOwnershipMarker', 'getOwnershipMarker', 'getSystemBuildIdentity'];
  if (required.some(name => typeof binding[name] !== 'function')) {
    throw Object.assign(new Error('OpenHarmony publication binding lacks required ownership operations'),
      { code: 'ERR_OHOS_PUBLICATION_BINDING_INVALID' });
  }
  installing = true;
  let ledger;
  try {
    const configuredHome = process.env.DSH_HOME;
    let home;
    try {
      if (typeof configuredHome !== 'string' || !isAbsolute(configuredHome) || configuredHome.includes('\0')) {
        throw new TypeError('DSH_HOME must be explicitly set to an absolute existing app-data directory');
      }
      home = await realpath(configuredHome);
      if (home === parse(home).root || !(await stat(home)).isDirectory()) {
        throw new TypeError('DSH_HOME must be an existing app-data directory other than the filesystem root');
      }
    } catch (cause) {
      throw Object.assign(new Error('OpenHarmony publication requires an explicit valid DSH_HOME', { cause }),
        { code: 'ERR_OHOS_PUBLICATION_DATA_DIRECTORY' });
    }
    // Read the actual platform identity before opening or mutating old state.
    // No environment variable, Node version or kernel release substitutes it.
    const build = readSystemBuildIdentity(binding.getSystemBuildIdentity);
    ledger = await openOwnershipLedger({
      directory: join(home, 'ohos-ownership'),
      ownerId: randomUUID(),
      lockExclusive: binding.lockExclusive,
      setOwnershipMarker: binding.setOwnershipMarker,
      getOwnershipMarker: binding.getOwnershipMarker,
    });
    const recovered = await ledger.recover();
    const atomicFuse = await openAtomicFuse({ storage: ledger.publicationAtomicState,
      ownerId: ledger.ownerId, systemVersion: build.systemVersion });
    const recoverySummary = Object.freeze(Object.fromEntries(Object.entries(recovered)
      .map(([name, rows]) => [name, Object.freeze(rows.map(row => Object.freeze({ ...row })))])));
    if (recoverySummary.unresolved.length) {
      process.emitWarning(`${recoverySummary.unresolved.length} publication ownership record(s) could not be safely recovered and were preserved.`,
        { code: 'OHOS_PUBLICATION_RECOVERY_UNRESOLVED' });
    }
    let fallbackWarningIssued = false;
    const atomicPublish = createAtomicPublisher({
      renameNoReplace: binding.renameNoReplace,
      ledger,
      atomicFuse,
      onFallback({ reason }) {
        if (fallbackWarningIssued) return;
        fallbackWarningIssued = true;
        const basis = reason === 'disabled-after-crash'
          ? 'An earlier renameat2 trial did not record normal completion and atomic publication is disabled for this system build.'
          : 'renameat2(RENAME_NOREPLACE) is unsupported for this system build after an EINVAL result.';
        process.emitWarning(`${basis} OpenHarmony publication is using exclusive copy; a partial final file can remain after failure or process death.`,
          { code: 'OHOS_PUBLICATION_NONATOMIC_FALLBACK' });
      },
    });
    const publish = async (source, target, options = {}) => {
      try {
        return await atomicPublish(source, target, options);
      } catch (error) {
        // EEXIST is a benign publication race: the caller verifies the existing
        // target's digest, so never overwrite it. Explicit atomic callers keep
        // the strict failure and their durability contract stays intact.
        if (error?.code === 'EEXIST' || options?.requireAtomic === true) throw error;
        process.emitWarning(
          `OpenHarmony atomic publication failed (${error?.code ?? 'unknown'}); using exclusive copy fallback: ${error?.message ?? error}`,
          { code: 'OHOS_PUBLICATION_EXCLUSIVE_COPY_FALLBACK' });
        return exclusiveCopyFallback(source, target, options?.fs);
      }
    };
    Object.defineProperty(publish, 'pendingCount', { get: () => atomicPublish.pendingCount });
    const service = Object.freeze({
      protocolVersion: 1,
      recovery: 'durable ledger; unidentified or replaced entries are preserved',
      ownerId: ledger.ownerId,
      recoverySummary,
      get atomic() { return atomicFuse.atomic; },
      systemVersion: build.systemVersion,
      systemBuildIdentity: build.identity,
      get pendingCount() { return publish.pendingCount; },
      publish,
      publishAtomic(source, target, options = {}) {
        return publish(source, target, { ...options, requireAtomic: true });
      },
    });
    Object.defineProperty(globalThis, publicationSymbol, { value: service });
    installedOwnership = Object.freeze({
      ownerId: ledger.ownerId,
      reserve: ledger.reserve,
      identify: ledger.identify,
      release: ledger.release,
    });
    return { installed: true, protocolVersion: service.protocolVersion };
  } catch (error) {
    if (ledger) {
      try { await ledger.close(); }
      catch (closeError) { throw new AggregateError([error, closeError], 'Publication startup and ledger close failed', { cause: error }); }
    }
    throw error;
  } finally { installing = false; }
}
