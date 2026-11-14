// Link ids and expiry tiers.
//
// An id is 10 base62 characters. Its first character also says how long the
// link lives, so a read finds the object without an index: the alphabet is cut
// into runs, one per tier, and the object sits under that tier's prefix in R2,
// where a lifecycle rule deletes it on time.
//
// New links live 1 day or 7 days. Links made before that (30 days, 永久) keep
// working: the 30-day run now hands out 1-day ids, so an id there is looked up
// under 1d/ first and then under 30d/; the 永久 run hands out nothing new.

export const ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
export const ID_LENGTH = 10;

/** What a new link can be given. */
export type Ttl = '1d' | '7d';
/** Every tier a stored link can be in, including the retired ones. */
export type StoredTtl = Ttl | '30d' | 'forever';

export interface Tier {
  ttl: StoredTtl;
  /** R2 key prefix; the lifecycle rules match these. */
  prefix: string;
  /** Lifetime in days, null for no expiry. */
  days: number | null;
  /** First-character run [from, to) in [ALPHABET]. */
  from: number;
  to: number;
}

/** Tiers new links are made in. */
export const TIERS: readonly Tier[] = [
  { ttl: '7d', prefix: '7d/', days: 7, from: 0, to: 20 }, // 0-9 A-J
  { ttl: '1d', prefix: '1d/', days: 1, from: 20, to: 40 }, // K-Z a-d
];

/** Retired tiers: only read and deleted, never written. */
export const RETIRED_TIERS: readonly Tier[] = [
  { ttl: '30d', prefix: '30d/', days: 30, from: 20, to: 40 }, // K-Z a-d, before 1d took it
  { ttl: 'forever', prefix: 'keep/', days: null, from: 40, to: 62 }, // e-z
];

export const DEFAULT_TTL: Ttl = '7d';

const ID_PATTERN = new RegExp(`^[0-9A-Za-z]{${ID_LENGTH}}$`);

/**
 * The tier for an upload's `ttl`. Older apps still ask for 30d or forever;
 * those get 7 days, the longest there is now.
 */
export function parseTtl(value: string | null): Ttl | null {
  if (value === null || value === '') return DEFAULT_TTL;
  if (value === '30d' || value === 'forever') return '7d';
  return TIERS.some((t) => t.ttl === value) ? (value as Ttl) : null;
}

export function tierOfTtl(ttl: Ttl): Tier {
  return TIERS.find((t) => t.ttl === ttl)!;
}

/** Where an id may be stored, in the order to look; empty when it isn't one of ours. */
export function tiersOfId(id: string): Tier[] {
  if (!ID_PATTERN.test(id)) return [];
  const at = ALPHABET.indexOf(id[0]!);
  return [...TIERS, ...RETIRED_TIERS].filter((t) => at >= t.from && at < t.to);
}

export function newId(ttl: Ttl): string {
  const tier = tierOfTtl(ttl);
  // Consume a fresh block within this ID, instead of discarding it after each character.
  const buf = new Uint8Array(16);
  let at = buf.length;
  function randomBelow(n: number): number {
    const limit = 256 - (256 % n);
    for (;;) {
      if (at === buf.length) {
        crypto.getRandomValues(buf);
        at = 0;
      }
      const b = buf[at++]!;
      if (b < limit) return b % n;
    }
  }
  let id = ALPHABET[tier.from + randomBelow(tier.to - tier.from)]!;
  while (id.length < ID_LENGTH) id += ALPHABET[randomBelow(ALPHABET.length)]!;
  return id;
}

/** When an object uploaded at [uploaded] stops being served; null for never. */
export function expiresAt(tier: Tier, uploaded: Date): Date | null {
  return tier.days === null ? null : new Date(uploaded.getTime() + tier.days * 86_400_000);
}
