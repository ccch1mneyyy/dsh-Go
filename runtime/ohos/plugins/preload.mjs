import { isMainThread, getEnvironmentData, setEnvironmentData, workerData } from 'node:worker_threads';

const probe = globalThis[Symbol.for('dsh.go.ohos.linkProbe')];
probe?.('plugins.preload.begin', { platform: process.platform, isMainThread,
  internalProtocol: workerData?.dshOhosVirtualProcess?.protocol ?? workerData?.dshOhosNodeScript?.protocol ?? null });

if (process.platform === 'openharmony') {
  const internal = !isMainThread && (workerData?.dshOhosVirtualProcess?.protocol === 1 ||
    workerData?.dshOhosNodeScript?.protocol === 1);
  // Dedicated command Workers have their own cwd/fs/child_process guards.
  // The managed-plugin resolver scans profile ancestors and must not enter
  // their private command namespace. Main and ordinary Workers keep it.
  if (!internal) {
    const { installPluginResolution } = await import('./resolution.mjs');
    installPluginResolution();
  }
  if (isMainThread) {
    try {
      const { createPluginBackend } = await import('./backend.mjs');
      globalThis[Symbol.for('dsh.go.ohos.plugins')] ??= createPluginBackend();
      probe?.('plugins.backend', { registered: true,
        keys: Object.keys(globalThis[Symbol.for('dsh.go.ohos.plugins')]) });
    } catch (error) {
      probe?.('plugins.backend', { registered: false, code: error?.code ?? null, message: error?.message ?? null });
    }
  } else {
    const profileKey = '@deepseek-ai/dsh-app-boot/profile-resolution';
    // Only the internal provider constructors select these protocols. They
    // retain independent module roots and scrubbed command environments; they
    // must not load the app's native profile resolver before their own entry.
    // Clear this Worker's inherited registration for its descendants as well.
    // This grants no authority and never changes the parent's registration.
    if (internal) setEnvironmentData(profileKey, undefined);
    const registration = getEnvironmentData(profileKey);
    if (registration !== undefined) {
      const { profilePackageRoots } = await import('./store.mjs');
      if (registration.resolution.profileDir !== undefined) profilePackageRoots(registration.resolution.profileDir);
      await import('@deepseek-ai/dsh-app-boot/worker/profile-resolution-bootstrap');
    }
  }
}
