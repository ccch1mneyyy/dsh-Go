// Pure projections of one call: the native card (dsh-go view) and the text the
// model reads. No I/O, so they run in tests and inside presentationMeta.

/** @typedef {{ id: string, status: string, transcript?: any[], end_reason?: string, duration_seconds?: number, started_at?: string, direction?: string }} Call */

const STATUS = {
  ringing: ['正在呼叫', 'Ringing'],
  in_progress: ['通话中', 'In call'],
  completed: ['已结束', 'Ended'],
  no_answer: ['无人接听', 'No answer'],
  rejected: ['被拒接', 'Rejected'],
  failed: ['失败', 'Failed'],
}

const NOTE = {
  in_progress: [
    '机主已接听，正在和语音助手实时对话。通话结束后会有一条摘要发到 WhatsApp；要逐句内容用 whatsapp_call_status。',
    'The owner answered and is talking with the voice agent now. A summary follows on WhatsApp when the call ends; use whatsapp_call_status for the transcript.',
  ],
  no_answer: [
    '机主没有接。如果这件事重要，现在换一个渠道：加急提醒或直接发消息。',
    'The owner did not pick up. If this matters, use another channel now: an urgent reminder or a message.',
  ],
  rejected: [
    '机主拒接了。不要重拨；换一个渠道联系。',
    'The owner rejected the call. Do not redial; use another channel.',
  ],
  ringing: [
    '还在响铃，已超过等待时间。用 whatsapp_call_status 再看一次。',
    'Still ringing past the wait; check again with whatsapp_call_status.',
  ],
}

/**
 * @param {Call} call
 * @param {'zh' | 'en'} lang
 * @returns {{ zh: string, en: string }}
 */
function statusLabel(call, lang) {
  const hit = STATUS[call?.status]
  if (hit === undefined) return { zh: call?.status ?? '未知', en: call?.status ?? 'unknown' }
  return lang === 'zh' ? { zh: hit[0], en: hit[0] } : { zh: hit[1], en: hit[1] }
}

/** @param {number | undefined} seconds */
function duration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '—'
  const total = Math.round(seconds)
  const m = Math.floor(total / 60)
  const s = total % 60
  return m === 0 ? `${s}s` : `${m}m ${String(s).padStart(2, '0')}s`
}

/** One line per transcript turn: `You: …` / `Agent: …`. */
function turnLine(turn, lang) {
  const who = turn?.role === 'owner' || turn?.speaker === 'owner'
    ? (lang === 'zh' ? '你' : 'You')
    : (lang === 'zh' ? '助手' : 'Agent')
  const text = typeof turn?.text === 'string' ? turn.text.trim() : ''
  return text === '' ? undefined : `${who}: ${text}`
}

/**
 * The text the model reads. Kept short: the card already shows the same facts.
 * @param {Call} call @param {'zh' | 'en'} lang
 */
export function callText(call, lang) {
  const label = statusLabel(call, lang)[lang]
  const lines = [
    lang === 'zh' ? `WhatsApp 语音通话 ${call?.id ?? ''}`.trim() : `WhatsApp voice call ${call?.id ?? ''}`.trim(),
    lang === 'zh' ? `状态：${label}` : `Status: ${label}`,
  ]
  if (Number.isFinite(call?.duration_seconds)) {
    lines.push(lang === 'zh' ? `通话时长：${duration(call.duration_seconds)}` : `Duration: ${duration(call.duration_seconds)}`)
  }
  if (typeof call?.end_reason === 'string' && call.end_reason !== '') {
    lines.push(lang === 'zh' ? `结束原因：${call.end_reason}` : `End reason: ${call.end_reason}`)
  }
  const note = NOTE[call?.status]?.[lang === 'zh' ? 0 : 1]
  if (note !== undefined) lines.push(note)
  const turns = (Array.isArray(call?.transcript) ? call.transcript : []).map((t) => turnLine(t, lang)).filter(Boolean)
  if (turns.length > 0) {
    lines.push(lang === 'zh' ? '对话记录：' : 'Transcript:')
    lines.push(...turns.slice(-6))
  }
  return lines.join('\n')
}

/**
 * The native card. View v1 only (stack/row/metric/list/callout), so it also
 * renders on hosts that never learned v2.
 * @param {Call} call @param {'zh' | 'en'} lang
 */
export function callView(call, lang) {
  const zh = lang !== 'en'
  const labels = statusLabel(call, lang)
  const tone = call?.status === 'in_progress' || call?.status === 'completed' ? 'info'
    : call?.status === 'ringing' ? 'info'
    : 'warn'

  const metrics = [{ type: 'metric', label: zh ? '状态' : 'Status', value: labels[lang] }]
  if (Number.isFinite(call?.duration_seconds)) {
    metrics.push({ type: 'metric', label: zh ? '时长' : 'Duration', value: duration(call.duration_seconds) })
  }
  if (typeof call?.direction === 'string' && call.direction !== '') {
    metrics.push({
      type: 'metric',
      label: zh ? '方向' : 'Direction',
      value: call.direction === 'inbound' ? (zh ? '机主呼入' : 'Inbound') : (zh ? '呼出' : 'Outbound'),
    })
  }

  const turns = (Array.isArray(call?.transcript) ? call.transcript : []).map((t) => turnLine(t, lang)).filter(Boolean)
  const children = [{ type: 'row', children: metrics }]
  if (turns.length > 0) {
    children.push({ type: 'list', items: turns.slice(-5).map((text) => ({ title: text })) })
  } else if (NOTE[call?.status] !== undefined) {
    children.push({ type: 'callout', tone, text: NOTE[call.status][zh ? 0 : 1] })
  }
  return {
    type: 'stack',
    title: zh ? 'WhatsApp 语音' : 'WhatsApp voice',
    children,
  }
}

/** The card as presentationMeta wants it: lossless JSON, or nothing. */
export function card(call, lang, maxBytes = 8 * 1024) {
  try {
    const text = JSON.stringify(callView(call, lang))
    if (text === undefined || Buffer.byteLength(text, 'utf8') > maxBytes) return {}
    return { 'dsh-go/view': JSON.parse(text) }
  } catch {
    return {}
  }
}
