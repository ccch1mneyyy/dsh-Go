// dsh-go-example-whatsapp-voice: live WhatsApp voice calls, ported from
// hermes-whatsapp-voice (same two tools, same sidecar contract, same fallback
// advice). The Rust sidecar owns the linked WhatsApp device and the Gemini Live
// session; this plugin only speaks its HTTP API, so the audio never passes
// through the engine and the plugin stays a plain tool provider.
//
// Configuration is three environment variables on the host that runs DSH:
//   WHATSAPP_VOICE_SIDECAR_URL  default http://127.0.0.1:8796
//   WHATSAPP_VOICE_TOKEN        the sidecar's bearer token (sidecar.token)
//   WHATSAPP_VOICE_OWNER        the only number that is called / answered
import { defineTool } from '@deepseek-ai/dsh-tools'
import { sidecarConfig } from './sidecar.js'
import { createTools, lang, statusText } from './tools.js'
import { callText, callView, card } from './view.js'

export const name = 'dsh-go-example-whatsapp-voice'
export const inject = ['tools']

export function apply(ctx, options = {}) {
  const { callOwner, callStatus } = createTools(options.config ?? sidecarConfig(options), options.timing)

  ctx.tools.register(defineTool({
    name: 'whatsapp_call_owner',
    description:
      'Place a live WhatsApp voice call to the owner. A voice agent talks with them in real time. ' +
      'It always calls the owner’s own number; there is no way to call anyone else. Use it for things ' +
      'important or time-sensitive enough to interrupt someone: a top-priority reminder, an urgent alert, ' +
      'or when the owner asked to be called. Returns once the call is answered or clearly not answered.',
    parameters: {
      reason: { type: 'string', required: true, description: 'What the call is about, one or two sentences. The voice opens with this.' },
      details: { type: 'string', description: 'Background the voice should know during the call (deadlines, options, numbers).' },
      language: { type: 'string', enum: ['zh', 'en'], description: "Language of the user's message. Default zh." },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: true,
        properties: {
          call_id: { type: 'string' },
          status: { type: 'string' },
          note: { type: 'string' },
          error: { type: 'string' },
          end_reason: { type: 'string' },
          duration_seconds: { type: 'number' },
          transcript: { type: 'array', items: { type: 'object', additionalProperties: true } },
        },
      },
      render: (args, value) => [{ type: 'text', text: value?.error ? String(value.error) : callText(value, lang(args)) }],
      presentationMeta: (args, value) => (value?.error ? {} : card(value, lang(args))),
    },
    timeoutMs: 180_000,
    isConcurrencySafe: () => false,
    execute: (args) => callOwner(args),
  }))

  ctx.tools.register(defineTool({
    name: 'whatsapp_call_status',
    description:
      'Status and transcript of a WhatsApp voice call. Pass the call_id that whatsapp_call_owner returned; ' +
      'leave it out to list the most recent calls.',
    parameters: {
      call_id: { type: 'string', description: 'Call id from whatsapp_call_owner.' },
      language: { type: 'string', enum: ['zh', 'en'], description: "Language of the user's message. Default zh." },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: true,
        properties: {
          call: { type: 'object', additionalProperties: true },
          calls: { type: 'array', items: { type: 'object', additionalProperties: true } },
          error: { type: 'string' },
          note: { type: 'string' },
        },
      },
      render: (args, value) => [{ type: 'text', text: statusText(value, lang(args)) }],
      presentationMeta: (args, value) => {
        const one = value?.call ?? (Array.isArray(value?.calls) && value.calls.length > 0 ? value.calls[0] : undefined)
        return one === undefined ? {} : card(one, lang(args))
      },
    },
    timeoutMs: 30_000,
    isConcurrencySafe: () => true,
    execute: (args) => callStatus(args),
  }))
}

export { callView }
