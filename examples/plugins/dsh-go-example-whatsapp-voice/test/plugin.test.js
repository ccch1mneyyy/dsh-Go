// Every test runs against a fake sidecar on 127.0.0.1, so nothing here needs
// WhatsApp, Gemini, the Rust binary, or the network.
import { registeredTools } from './dsh-tools.js'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { test } from 'node:test'
import { createTools, statusText } from '../lib/tools.js'
import { callText, callView } from '../lib/view.js'
import { SidecarError, createClient, sidecarConfig } from '../lib/sidecar.js'

const { checkView } = await import('../../../sdk/plugin-kit/lib/check.js').catch(() => ({ checkView: undefined }))

/** A sidecar stand-in: records every request, answers from `routes`. */
async function fakeSidecar(routes = {}) {
  const seen = []
  const server = createServer((req, res) => {
    const chunks = []
    req.on('data', (c) => chunks.push(c))
    req.on('end', () => {
      const body = chunks.length === 0 ? undefined : JSON.parse(Buffer.concat(chunks).toString('utf8'))
      seen.push({ method: req.method, url: req.url, body, authorization: req.headers.authorization })
      const key = `${req.method} ${req.url.split('?')[0]}`
      const handler = routes[key] ?? routes[`${req.method} *`]
      if (handler === undefined) {
        res.writeHead(404, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ error: 'no route' }))
        return
      }
      const [status, payload] = handler(body, req.url)
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(payload === undefined ? '' : JSON.stringify(payload))
    })
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address()
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    seen,
    close: () => new Promise((resolve) => server.close(resolve)),
  }
}

/** Timing that never really waits: the poll loop thinks a second passed. */
function fakeTiming() {
  let clock = 0
  return { now: () => clock, sleep: async (ms) => { clock += ms } }
}

const config = (over) => sidecarConfig({ baseUrl: 'http://127.0.0.1:1', token: '', timeoutMs: 2000, ringTimeoutSeconds: 1, ...over })

test('call_owner places the call, waits, and reports the answer', async () => {
  const sidecar = await fakeSidecar({
    'POST /calls': () => [201, { id: 'c-1', status: 'ringing' }],
    'GET /calls/c-1': () => [200, { id: 'c-1', status: 'in_progress', duration_seconds: 3 }],
  })
  try {
    const tools = createTools(config({ baseUrl: sidecar.baseUrl }), fakeTiming())
    const out = await tools.callOwner({ reason: '提醒交水电费', details: '今天 18:00 前' })
    assert.equal(out.call_id, 'c-1')
    assert.equal(out.status, 'in_progress')
    assert.match(out.note, /已接听/)
    assert.deepEqual(sidecar.seen[0].body, { reason: '提醒交水电费', details: '今天 18:00 前' })
    assert.equal(sidecar.seen[1].url, '/calls/c-1')
  } finally {
    await sidecar.close()
  }
})

test('call_owner falls back to another channel when the owner does not pick up', async () => {
  const sidecar = await fakeSidecar({
    'POST /calls': () => [201, { id: 'c-2', status: 'ringing' }],
    'GET /calls/c-2': () => [200, { id: 'c-2', status: 'no_answer' }],
  })
  try {
    const tools = createTools(config({ baseUrl: sidecar.baseUrl }), fakeTiming())
    const out = await tools.callOwner({ reason: 'urgent', language: 'en' })
    assert.equal(out.status, 'no_answer')
    assert.match(out.note, /use another channel/)
  } finally {
    await sidecar.close()
  }
})

test('call_owner stops polling at the ring timeout instead of hanging', async () => {
  let polls = 0
  const sidecar = await fakeSidecar({
    'POST /calls': () => [201, { id: 'c-3', status: 'ringing' }],
    'GET /calls/c-3': () => { polls += 1; return [200, { id: 'c-3', status: 'ringing' }] },
  })
  try {
    const tools = createTools(config({ baseUrl: sidecar.baseUrl, ringTimeoutSeconds: 1 }), fakeTiming())
    const out = await tools.callOwner({ reason: 'still ringing' })
    assert.equal(out.status, 'ringing')
    assert.match(out.note, /再看一次/)
    assert.ok(polls > 0 && polls < 40, `polled ${polls} times`)
  } finally {
    await sidecar.close()
  }
})

test('call_owner refuses an empty reason without touching the sidecar', async () => {
  const sidecar = await fakeSidecar({})
  try {
    const tools = createTools(config({ baseUrl: sidecar.baseUrl }), fakeTiming())
    const out = await tools.callOwner({ reason: '   ' })
    assert.match(out.error, /reason/)
    assert.equal(sidecar.seen.length, 0)
  } finally {
    await sidecar.close()
  }
})

test('call_status reads one call by id, or lists the recent ones', async () => {
  const sidecar = await fakeSidecar({
    'GET /calls/c-9': () => [200, { id: 'c-9', status: 'completed', transcript: [{ role: 'owner', text: '谢谢' }] }],
    'GET /calls': () => [200, { calls: [{ id: 'c-9', status: 'completed' }, { id: 'c-8', status: 'no_answer' }] }],
  })
  try {
    const tools = createTools(config({ baseUrl: sidecar.baseUrl }), fakeTiming())
    const one = await tools.callStatus({ call_id: 'c-9' })
    assert.equal(one.call.id, 'c-9')
    const many = await tools.callStatus({})
    assert.equal(many.calls.length, 2)
    assert.equal(sidecar.seen.at(-1).url, '/calls?limit=5')
  } finally {
    await sidecar.close()
  }
})

test('a sidecar that is not running becomes an error result, not a thrown tool', async () => {
  const tools = createTools(config({ baseUrl: 'http://127.0.0.1:1', timeoutMs: 1500 }), fakeTiming())
  const out = await tools.callOwner({ reason: 'x' })
  assert.match(out.error, /not reachable|reachable at/)
  assert.match(out.note, /别的渠道/)
})

test('the bearer token travels on every request', async () => {
  const sidecar = await fakeSidecar({ 'GET /health': () => [200, { ok: true }] })
  try {
    const client = createClient(config({ baseUrl: sidecar.baseUrl, token: 's3cret' }))
    assert.deepEqual(await client.health(), { ok: true })
    assert.equal(sidecar.seen[0].authorization, 'Bearer s3cret')
  } finally {
    await sidecar.close()
  }
})

test('sidecar errors carry the status and the sidecar message', async () => {
  const sidecar = await fakeSidecar({ 'POST /calls': () => [400, { error: 'owner_number is not configured' }] })
  try {
    const client = createClient(config({ baseUrl: sidecar.baseUrl }))
    await assert.rejects(() => client.startCall('x'), (error) => {
      assert.ok(error instanceof SidecarError)
      assert.equal(error.status, 400)
      assert.match(error.message, /owner_number is not configured/)
      return true
    })
  } finally {
    await sidecar.close()
  }
})

test('both tools are registered with the sidecar contract', async () => {
  const tools = await registeredTools()
  assert.deepEqual([...tools.keys()].sort(), ['whatsapp_call_owner', 'whatsapp_call_status'])
  const callOwner = tools.get('whatsapp_call_owner')
  assert.equal(callOwner.parameters.reason.required, true)
  assert.equal(callOwner.isConcurrencySafe(), false)
  assert.equal(tools.get('whatsapp_call_status').parameters.call_id.required, undefined)
})

test('every call status renders a card the app can draw', () => {
  const calls = [
    { id: 'c1', status: 'in_progress', duration_seconds: 42, direction: 'outbound' },
    { id: 'c2', status: 'completed', duration_seconds: 185, transcript: [{ role: 'owner', text: '喂' }, { role: 'agent', text: '你好' }] },
    { id: 'c3', status: 'no_answer' },
    { id: 'c4', status: 'failed', end_reason: 'gemini closed' },
    { id: 'c5', status: 'ringing' },
  ]
  for (const call of calls) {
    const view = callView(call, 'zh')
    assert.equal(view.type, 'stack')
    if (checkView !== undefined) {
      const report = checkView(view, { budget: 'toolCard', lang: 'zh' })
      assert.equal(report.ok, true, `${call.status}: ${JSON.stringify(report.issues)}`)
    }
  }
})

test('the text the model reads keeps the facts the card shows', () => {
  const text = callText({ id: 'c2', status: 'completed', duration_seconds: 185, transcript: [{ role: 'owner', text: '喂' }] }, 'zh')
  assert.match(text, /c2/)
  assert.match(text, /已结束/)
  assert.match(text, /3m 05s/)
  assert.match(text, /你: 喂/)
})
