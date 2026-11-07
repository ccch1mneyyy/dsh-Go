// Package rows of GET /dsh-go/v1/inventory (issue #32).
//
// `packages` keeps its old membership (client-graph packages plus loader entries that
// have a fiber) and only gains a `status` field. Packages the loader knows but that never
// started (disabled, or not running) are listed separately in `unavailable`, so older
// apps that treat every `packages` row as present see exactly what they saw before.

// Fiber states as used by plugin-config.js: 2 = active, 3 = failed.
const ACTIVE = 2;
const FAILED = 3;
const ERROR_MAX = 300;

export const isOfficial = (pkg) => typeof pkg === "string" && pkg.startsWith("@deepseek-ai/");

export function packageOf(specifier) {
  if (typeof specifier !== "string" || specifier === "" || /^(\.|\/|file:|cordis:|[A-Za-z]:)/.test(specifier)) return undefined;
  const parts = specifier.split("/");
  return specifier.startsWith("@") ? (parts.length >= 2 ? `${parts[0]}/${parts[1]}` : undefined) : parts[0];
}

/** loaded | failed | disabled | inactive, for one loader entry. */
export function entryStatus(entry) {
  if (entry?.disabled) return "disabled";
  const state = entry?.fiber?.state;
  if (entry?.fiber === undefined) return "inactive";
  if (state === FAILED) return "failed";
  if (state === ACTIVE || state === undefined) return "loaded";
  return "inactive";
}

/** First line of the fiber's error plus the first stack frame location, bounded; or undefined. */
export function errorSummary(entry) {
  const error = entry?.fiber?.error ?? entry?.error;
  if (error == null) return undefined;
  const message = typeof error === "string" ? error : typeof error.message === "string" ? error.message : undefined;
  if (message === undefined) return undefined;
  let text = message.split("\n")[0].trim();
  const at = typeof error.stack === "string" ? /\(?((?:file:\/\/)?\/[^\s()]+:\d+:\d+)\)?/.exec(error.stack)?.[1] : undefined;
  if (at) text += ` (${at})`;
  return text.length > ERROR_MAX ? `${text.slice(0, ERROR_MAX - 1)}…` : text || undefined;
}

const RANK = { loaded: 0, failed: 1, inactive: 2, disabled: 3 };

export function packageInventory(loaderEntries, graph, onError) {
  const packages = new Map();
  const unavailable = new Map();
  for (const entry of graph?.entries ?? []) {
    if (typeof entry?.id === "string") {
      packages.set(entry.id, { name: entry.id, hasClient: true, rev: entry.rev ?? null, official: isOfficial(entry.id), status: "loaded" });
    }
  }
  const loaderStatus = new Map();
  try {
    for (const entry of loaderEntries() ?? []) {
      const pkg = packageOf(entry?.options?.name);
      if (pkg === undefined) continue;
      const status = entryStatus(entry);
      const error = status === "failed" ? errorSummary(entry) : undefined;
      // One package may own several entries; report its worst-but-most-telling state.
      const prev = loaderStatus.get(pkg);
      if (prev === undefined || (status === "failed" && prev.status !== "failed")) loaderStatus.set(pkg, { status, error, hasFiber: entry.fiber !== undefined && !entry.disabled });
      else if (entry.fiber !== undefined && !entry.disabled) prev.hasFiber = true;
    }
  } catch (error) {
    onError?.(error);
  }
  for (const [pkg, info] of loaderStatus) {
    const row = packages.get(pkg);
    if (row !== undefined) {
      if (info.status === "failed") Object.assign(row, { status: "failed" }, info.error ? { error: info.error } : {});
    } else if (info.hasFiber) {
      packages.set(pkg, { name: pkg, hasClient: false, rev: null, official: isOfficial(pkg), status: info.status, ...(info.error ? { error: info.error } : {}) });
    } else {
      unavailable.set(pkg, { name: pkg, official: isOfficial(pkg), status: info.status, ...(info.error ? { error: info.error } : {}) });
    }
  }
  const byName = (a, b) => a.name.localeCompare(b.name);
  return {
    packages: [...packages.values()].sort(byName),
    unavailable: [...unavailable.values()].sort((a, b) => (RANK[a.status] - RANK[b.status]) || byName(a, b)),
  };
}
