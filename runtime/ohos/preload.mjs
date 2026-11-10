// The product host's sole --import. Install the OS-child-process boundary before
// dependencies can capture builtin aliases. Keep sequential dynamic imports:
// network bootstrap must finish before publication's dependencies are evaluated.
//
// Link probe: every stage writes one [DSH-LINK] line to stderr. The Ark host
// pipes Node's stderr into RuntimeLogs, so the in-app diagnostics export
// (engine.log) shows exactly which stage ran and which one failed on device.
// The probe is registered on globalThis so sibling preloads can report without
// adding imports (the composition import graph stays byte-identical).
const linkProbeSymbol = Symbol.for('dsh.go.ohos.linkProbe');
const linkProbe = (stage, detail) => {
  // A device diagnostic only: quiet in a shipped build (DSH_LINK_PROBE=1 turns
  // it back on). Kept as a function so sibling preloads can still call it.
  if (process.env.DSH_LINK_PROBE !== '1') return;
  try {
    const text = typeof detail === 'string' ? detail : JSON.stringify(detail);
    console.error(`[DSH-LINK] ${stage} ${text}`);
  } catch { /* a probe must never break startup */ }
};
globalThis[linkProbeSymbol] = linkProbe;
linkProbe('preload.begin', { platform: process.platform, node: process.versions.node,
  argv1: process.argv[1], dshHome: process.env.DSH_HOME ?? null });

// Security and path boundaries are mandatory: a failure here must abort
// startup rather than run the engine without the OS-child-process guard.
const mandatory = async (name, load) => {
  try { await load(); linkProbe('preload.mandatory', `${name} ok`); }
  catch (error) { linkProbe('preload.mandatory', `${name} FAILED code=${error?.code} msg=${error?.message}`); throw error; }
};
await mandatory('child-process', () => import('./process/child-process.mjs'));
const { installProcessGrantAuthority } = await import('./process/files/process-authority.mjs');
installProcessGrantAuthority();
await mandatory('process-authority', () => Promise.resolve());
await mandatory('workspace-paths', () => import('./process/files/workspace-paths.mjs'));
await mandatory('workspace-edit', () => import('./process/files/workspace-edit.mjs'));
await mandatory('linux-host-paths', () => import('./linux/host-paths.mjs'));
await mandatory('net-dsh-preload', () => import('./net/dsh-preload.mjs'));

// Publication and plugin backends are independent capabilities. A failure in
// one must NOT prevent the other from registering: on some OHOS builds the
// native publication binding is unavailable, and the original serial chain
// would then leave the plugin backend (and its market installer) unregistered
// for the entire process lifetime. Report and continue instead.
const optional = async (name, load) => {
  try { await load(); linkProbe('preload.optional', `${name} ok`); }
  catch (error) { linkProbe('preload.optional', `${name} FAILED code=${error?.code} msg=${error?.message}`); }
};
await optional('publication-preload', () => import('./publication/preload.mjs'));
await optional('plugins-preload', () => import('./plugins/preload.mjs'));
await optional('node-worker-preload', () => import('./process/node-worker-preload.mjs'));

const pub = globalThis[Symbol.for('dsh.go.ohos.publication')];
const plg = globalThis[Symbol.for('dsh.go.ohos.plugins')];
linkProbe('preload.end', {
  publication: pub ? { protocolVersion: pub.protocolVersion, atomic: pub.atomic, publish: typeof pub.publish } : 'MISSING',
  pluginBackend: plg ? Object.keys(plg) : 'MISSING',
  net: globalThis[Symbol.for('dsh.go.ohos.net')] ? 'installed' : 'MISSING',
});
