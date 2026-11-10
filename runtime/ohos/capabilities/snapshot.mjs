import { readPublicationCapabilities } from '../publication/capabilities.mjs';

const support = value => value === true ? 'supported' : value === false ? 'unsupported' : 'unknown';
const choice = (value, allowed) => allowed.includes(value) ? value : 'unknown';

// A registered, live boundary owner is required. A GET only reads its state;
// it never opens a journal, acknowledges an unknown, or resumes any work.
function lifecycleCapabilities(ctx) {
  try {
    const owner = ctx.get('ohosLifecycle');
    if (owner?.protocolVersion === 1 && typeof owner.status === 'function') {
      const state = owner.status();
      if (state?.v === 1 && state.closed === false) return {
        computePermission: choice(state.host?.computePermission, ['granted', 'denied']),
        resume: state.blocked === false ? 'reconcile' : 'none',
      };
    }
  } catch {}
  return { computePermission: 'unknown', resume: 'none' };
}

// Read installed services only. This must not load an addon, probe a command,
// inspect the filesystem, or retry a publication while answering a GET.
export function runtimeCapabilities(ctx, bootId) {
  const subprocess = ctx.get('subprocess')?.capabilities;
  const shell = ctx.get('shell');
  const storage = ctx.get('sessionPersistence')?.dshGoRuntimeCapabilities;
  const loader = ctx.get('loader');
  const bundles = ctx.get('profileContext')?.startedBundles;
  const bundled = Array.isArray(bundles) && bundles.length > 0 && loader !== undefined &&
    [...loader.entries()].some(entry => !entry.disabled && entry.fiber?.state === 2 &&
      typeof entry.options.name === 'string' && entry.options.name.startsWith('@deepseek-ai/'));
  // ctx.get(name) is strict by default: it hides a service whose providing
  // fiber has not reached the active state yet. The first capabilities GET can
  // land while the profile is still starting, and the client caches the answer
  // for the lifetime of a connection. Reporting that transient state as
  // "unsupported" permanently disables plugin installation in the UI, so read
  // non-strictly and keep the answer unknown until both the pure-JS install
  // backend and its Cordis owner are present.
  const pluginBackend = globalThis[Symbol.for('dsh.go.ohos.plugins')];
  const pluginManager = ctx.get('pluginManager', false);
  const marketInstall = process.platform === 'openharmony'
    ? pluginBackend === undefined ? false
      : pluginManager === undefined ? undefined
      : true
    : false;
  const commands = subprocess?.commands;
  globalThis[Symbol.for('dsh.go.ohos.linkProbe')]?.('capabilities.snapshot', {
    platform: process.platform, bundled, pluginBackend: pluginBackend === undefined ? 'MISSING' : 'present',
    pluginManager: pluginManager === undefined ? 'MISSING' : 'present', marketInstall,
    startedBundles: Array.isArray(bundles) ? bundles.length : 'none', loader: loader === undefined ? 'MISSING' : 'present',
  });
  return {
    v: 1, bootId, platform: process.platform, arch: process.arch,
    nodeVersion: process.versions.node, simulated: globalThis[Symbol.for('dsh.go.ohos.sim')] === true,
    shell: {
      kind: shell === undefined ? 'none' : choice(subprocess?.kind, ['virtual', 'system', 'none']),
      commands: shell === undefined ? [] : Array.isArray(commands) && commands.every(value => typeof value === 'string') ? [...commands] : null,
      pty: shell === undefined ? 'unsupported' : support(subprocess?.pty),
    },
    processSpawn: support(subprocess?.processSpawn),
    nodeScripts: choice(subprocess?.nodeScripts, ['worker', 'worker-rebased', 'process', 'none']),
    python: support(subprocess?.python),
    // Presence alone does not prove that code generation is permitted.
    wasm: typeof globalThis.WebAssembly === 'undefined' ? 'unsupported' : 'unknown',
    plugins: { bundled: bundled ? 'supported' : 'unknown', marketInstall: support(marketInstall) },
    // The signed HAP's native inventory and per-module load observations are
    // not yet supplied by the host. Do not turn a package name into "loaded".
    nativeModules: null,
    storage: { sessionLock: choice(storage?.sessionLock, ['kernel', 'main-thread', 'none']) },
    background: { policy: 'may-freeze', ...lifecycleCapabilities(ctx) },
    ...readPublicationCapabilities(),
  };
}
