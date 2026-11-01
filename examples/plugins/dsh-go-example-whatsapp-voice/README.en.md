# dsh-go-example-whatsapp-voice

[中文](README.md)

Live WhatsApp voice calls for DSH, ported from
[`hermes-whatsapp-voice`](https://github.com/ashwanthbalakrishnan5/hermes-whatsapp-voice):
**the same two tools, the same sidecar contract, the same "it did not pick up, use another channel" advice.**

- `whatsapp_call_owner` — place a real WhatsApp voice call to the owner; a voice agent talks with them live.
- `whatsapp_call_status` — one call's status and transcript, or the most recent calls.

Results render as a native card (`presentationMeta`): status, duration, direction and the last few turns.

## Why a plugin plus a sidecar

A WhatsApp voice call needs an end-to-end-encrypted realtime stream and Gemini Live's two-way audio, held by a
long-lived process that owns the linked-device session. A DSH plugin is a JS module inside the engine and should
not carry that. So:

```
user/model ──► DSH tool ──HTTP──► sidecar (Rust, owns WhatsApp + Gemini Live) ──► the phone
                    ◄── status / transcript ──┘
```

The plugin does three things: turn the tool arguments into one `POST /calls`, poll until the call settles, and
draw the result. No audio ever passes through DSH.

## Requirements

| What | Notes |
|---|---|
| sidecar | the `hermes-wa-voice` binary from [hermes-whatsapp-voice](https://github.com/ashwanthbalakrishnan5/hermes-whatsapp-voice), running on the **same machine** as DSH |
| WhatsApp | the sidecar links a device by QR — that is the bot's own number |
| Gemini | a Gemini Live key, used by the sidecar |

## Install

```bash
dsh plugin --profile web add /absolute/path/dsh-go-example-whatsapp-voice
```

Then give the DSH process three environment variables (i.e. in the shell that starts `dsh web`):

| Variable | Default | Meaning |
|---|---|---|
| `WHATSAPP_VOICE_SIDECAR_URL` | `http://127.0.0.1:8796` | the sidecar's address (its `HWV_LISTEN`) |
| `WHATSAPP_VOICE_TOKEN` | empty | the sidecar's bearer token: `sidecar.token` in its data directory |
| `WHATSAPP_VOICE_OWNER` | empty | the only number called, and the only caller answered (E.164, e.g. `+60123456789`) |

`WHATSAPP_VOICE_OWNER` is informational: "only the owner" is enforced by the sidecar's `HWV_OWNER`.

## How the model uses it

```
user: watch the server and call me if it goes down
model → whatsapp_call_owner {reason: "the site returns 502, do we roll back?", details: "…"}
      ← {call_id, status: "in_progress", note: "the owner answered…"}
model → whatsapp_call_status {call_id: "…"}      # transcript once the call ends
```

- If the call is still ringing after the ring timeout (configured on the sidecar) plus 20s, the tool returns
  `status: "ringing"` and tells the model to check again — the tool call never hangs.
- `no_answer`, `rejected` and `failed` all carry the "use another channel" advice, exactly like the original.

## Test

```bash
npm test     # 11 tests against a fake sidecar: no WhatsApp, no Gemini, no Rust binary, no network
npm run check
```

## Limits

- **Only the owner.** The number comes from the sidecar's configuration; a `reason` cannot redirect a call.
- **No audio in DSH.** The plugin reads status and text only; recordings (`record_calls`) stay in the sidecar's
  data directory.
- **No sidecar, no calls.** The tools return a clear error instead of failing silently.
