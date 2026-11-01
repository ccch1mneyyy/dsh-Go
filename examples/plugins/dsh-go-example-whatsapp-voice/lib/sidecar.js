// The WhatsApp voice sidecar's HTTP API (the Rust process that owns the
// linked WhatsApp device and the Gemini Live session). This file is the only
// place that knows the wire format, so tests can point it at a fake server.
//
// Endpoints mirrored from hermes-whatsapp-voice/sidecar_client.py:
//   GET  /health                 -> { ok: true, ... }
//   POST /calls   {reason,details} -> call
//   GET  /calls/:id                -> call
//   GET  /calls?limit=N            -> { calls: [call] }
//   POST /calls/active/text {text} -> { ok: true }
// A call is { id, status, transcript?, end_reason?, started_at?, duration_seconds? }.
// Statuses: ringing, in_progress, completed, no_answer, rejected, failed.

export class SidecarError extends Error {
  /** @param {string} message @param {{ unreachable?: boolean, status?: number }} [meta] */
  constructor(message, meta = {}) {
    super(message)
    this.name = 'SidecarError'
    this.unreachable = meta.unreachable === true
    this.status = meta.status
  }
}

const DEFAULT_BASE = 'http://127.0.0.1:8796'

/**
 * Where the sidecar is and how to authenticate. Environment wins over nothing:
 * these three are the whole configuration, because a plugin cannot ask the user
 * for a form and the sidecar already holds every other setting.
 *
 * @param {{ baseUrl?: string, token?: string, owner?: string, timeoutMs?: number, ringTimeoutSeconds?: number }} [options]
 */
export function sidecarConfig(options = {}) {
  const env = process.env
  return {
    baseUrl: (options.baseUrl ?? env.WHATSAPP_VOICE_SIDECAR_URL ?? DEFAULT_BASE).replace(/\/+$/, ''),
    token: options.token ?? env.WHATSAPP_VOICE_TOKEN ?? '',
    owner: options.owner ?? env.WHATSAPP_VOICE_OWNER ?? '',
    timeoutMs: options.timeoutMs ?? 10_000,
    ringTimeoutSeconds: options.ringTimeoutSeconds ?? (Number(env.WHATSAPP_VOICE_RING_TIMEOUT_SECONDS) || 45),
  }
}

/**
 * @param {ReturnType<typeof sidecarConfig>} config
 * @param {typeof fetch} [fetchImpl]
 */
export function createClient(config, fetchImpl = globalThis.fetch) {
  async function request(method, path, body) {
    const headers = { accept: 'application/json' }
    if (config.token) headers.authorization = `Bearer ${config.token}`
    if (body !== undefined) headers['content-type'] = 'application/json'
    let response
    try {
      response = await fetchImpl(config.baseUrl + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(config.timeoutMs),
      })
    } catch (error) {
      // fetch rejects on refused connections, DNS failures and our own timeout.
      throw new SidecarError(
        `sidecar not reachable at ${config.baseUrl} (${error?.cause?.code ?? error?.name ?? error}); ` +
          'is the WhatsApp voice sidecar running?',
        { unreachable: true },
      )
    }
    const text = await response.text()
    let payload = {}
    if (text !== '') {
      try {
        payload = JSON.parse(text)
      } catch {
        throw new SidecarError(`sidecar returned non-JSON (${response.status}): ${text.slice(0, 200)}`, {
          status: response.status,
        })
      }
    }
    if (!response.ok) {
      const detail = typeof payload?.error === 'string' ? payload.error : response.statusText
      throw new SidecarError(`sidecar returned ${response.status}: ${detail}`, { status: response.status })
    }
    return payload
  }

  return {
    baseUrl: config.baseUrl,
    health: () => request('GET', '/health'),
    /** @param {string} reason @param {string} [details] */
    startCall: (reason, details = '') => request('POST', '/calls', { reason, details }),
    /** @param {string} id */
    getCall: (id) => request('GET', `/calls/${encodeURIComponent(id)}`),
    /** @param {number} [limit] */
    recentCalls: async (limit = 5) => {
      const payload = await request('GET', `/calls?limit=${encodeURIComponent(String(limit))}`)
      return Array.isArray(payload?.calls) ? payload.calls : []
    },
    /** Hand the owner's text to a running call. False when no call takes it. */
    textIntoCall: async (text) => {
      try {
        await request('POST', '/calls/active/text', { text })
        return true
      } catch (error) {
        if (error instanceof SidecarError && (error.status === 404 || error.status === 409)) return false
        throw error
      }
    },
  }
}

/** Statuses that mean the ringing phase is over (from tools.py). */
export const SETTLED = new Set(['in_progress', 'completed', 'no_answer', 'rejected', 'failed'])

/**
 * Poll a freshly placed call until it settles or the ring timeout passes.
 * The sidecar answers `POST /calls` as soon as it starts ringing, so the tool
 * has to wait for the interesting part itself.
 *
 * @param {ReturnType<typeof createClient>} client
 * @param {Record<string, any>} call
 * @param {{ ringTimeoutSeconds: number, now?: () => number, sleep?: (ms: number) => Promise<void> }} timing
 */
export async function waitForSettled(client, call, { ringTimeoutSeconds, now = Date.now, sleep = defaultSleep }) {
  const deadline = now() + (ringTimeoutSeconds + 20) * 1000
  let current = call
  while (!SETTLED.has(current?.status) && now() < deadline) {
    await sleep(1000)
    current = await client.getCall(current.id)
  }
  return current
}

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
