// The two operations, with no DSH imports: the unit tests and the tool
// definitions in index.js share exactly this code.
import { SETTLED, createClient, waitForSettled } from './sidecar.js'
import { callText } from './view.js'

export const lang = (args) => (args?.language === 'en' ? 'en' : 'zh')

const FALLBACK = {
  zh: '机主没有接。如果这件事重要，现在换一个渠道：加急提醒或直接发消息。',
  en: 'The owner did not pick up. If this matters, use another channel now: an urgent reminder or a message.',
}

/** Fold one settled call into the object the tool returns. */
function settle(call, l) {
  const out = { call_id: call?.id ?? '', status: call?.status ?? 'unknown' }
  if (Number.isFinite(call?.duration_seconds)) out.duration_seconds = call.duration_seconds
  if (typeof call?.end_reason === 'string' && call.end_reason !== '') out.end_reason = call.end_reason
  if (call?.status === 'in_progress') {
    out.note = l === 'zh'
      ? '机主已接听，正在和语音助手对话。通话结束后会有一条摘要发到 WhatsApp；要逐句内容用 whatsapp_call_status。'
      : 'The owner answered and is talking with the voice agent now. A summary follows when the call ends; use whatsapp_call_status for the transcript.'
  } else if (call?.status === 'completed') {
    out.transcript = Array.isArray(call.transcript) ? call.transcript : []
    out.note = l === 'zh' ? '通话已结束。' : 'The call ended.'
  } else if (call?.status === 'ringing') {
    out.note = l === 'zh'
      ? '还在响铃，已超过等待时间。用 whatsapp_call_status 再看一次。'
      : 'Still ringing past the wait; check again with whatsapp_call_status.'
  } else if (call?.status === 'failed') {
    out.error = call?.end_reason ?? 'call failed'
    out.note = FALLBACK[l]
  } else {
    out.note = FALLBACK[l]
  }
  return out
}

/**
 * @param {ReturnType<import('./sidecar.js').sidecarConfig>} config
 * @param {{ sleep?: (ms: number) => Promise<void>, now?: () => number }} [timing] injected by tests
 */
export function createTools(config, timing = {}) {
  const client = createClient(config)

  async function callOwner(args) {
    const l = lang(args)
    const reason = String(args?.reason ?? '').trim()
    if (reason === '') {
      return { error: 'reason is required', note: l === 'zh' ? '说清这通电话要讲什么。' : 'Say what the call is about.' }
    }
    try {
      const placed = await client.startCall(reason, String(args?.details ?? '').trim())
      if (SETTLED.has(placed?.status)) return settle(placed, l)
      const settled = await waitForSettled(client, placed, { ringTimeoutSeconds: config.ringTimeoutSeconds, ...timing })
      return settle(settled, l)
    } catch (error) {
      return {
        error: String(error?.message ?? error),
        note: l === 'zh'
          ? '拨不出去。先用别的渠道联系机主；如果是 sidecar 没起，见插件 README。'
          : 'Could not place the call. Reach the owner another way; if the sidecar is down, see the plugin README.',
      }
    }
  }

  async function callStatus(args) {
    const l = lang(args)
    const id = String(args?.call_id ?? '').trim()
    try {
      if (id !== '') return { call: await client.getCall(id) }
      return { calls: await client.recentCalls(5) }
    } catch (error) {
      return { error: String(error?.message ?? error), note: l === 'zh' ? '读不到通话记录。' : 'Could not read the calls.' }
    }
  }

  return { callOwner, callStatus, client }
}

/** Text for the status tool: one call, or a short list of the recent ones. */
export function statusText(value, l) {
  if (value?.error) return String(value.error)
  if (value?.call) return callText(value.call, l)
  const calls = Array.isArray(value?.calls) ? value.calls : []
  if (calls.length === 0) return l === 'zh' ? '最近没有通话记录。' : 'No recent calls.'
  const head = l === 'zh' ? '最近的通话：' : 'Recent calls:'
  return [head, ...calls.map((c) => callText(c, l).split('\n').slice(0, 2).join(' · '))].join('\n')
}
