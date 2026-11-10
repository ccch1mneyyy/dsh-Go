// Internal second step of ../preload.mjs; direct import is retained for isolated tests.
import { installPublication, installFallbackPublication, publicationSymbol } from './index.mjs';

let outcome;
try {
  outcome = await installPublication();
} catch (error) {
  // The native installer has many preconditions (exact Node version, a linked
  // binding with five operations, a valid DSH_HOME, a recoverable ownership
  // ledger, renameat2 support). Any failure here must not abort engine startup
  // nor leave the attachment store without a publication service.
  outcome = { installed: false, error };
}

// Guarantee a publication service on THIS thread's globalThis. The native
// installer intentionally skips worker threads (each isolate has its own
// globalThis), so a service registered on the main thread is invisible to a
// worker. publishOhosExclusive() reads the global service and throws
// ERR_OHOS_PUBLICATION_PRELOAD_MISSING when it is absent, which surfaces as a
// failed attachment upload. A pure-JS fallback keeps the same
// protocolVersion/publish contract and needs no native capability. When the
// native service is already present we keep it untouched.
const probe = globalThis[Symbol.for('dsh.go.ohos.linkProbe')];
probe?.('publication.install', { installed: outcome?.installed ?? false,
  reason: outcome?.reason ?? null, error: outcome?.error?.code ?? outcome?.error?.message ?? null });
const service = globalThis[publicationSymbol];
if (service?.protocolVersion !== 1 || typeof service.publish !== 'function') {
  const fallback = installFallbackPublication(outcome?.error ?? outcome?.reason ?? 'publication-unavailable');
  probe?.('publication.fallback', fallback);
}
const final = globalThis[publicationSymbol];
probe?.('publication.ready', final
  ? { protocolVersion: final.protocolVersion, atomic: final.atomic, publish: typeof final.publish }
  : 'MISSING');
