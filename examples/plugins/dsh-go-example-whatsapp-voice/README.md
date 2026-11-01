# dsh-go-example-whatsapp-voice

[English](README.en.md)

把 [`hermes-whatsapp-voice`](https://github.com/ashwanthbalakrishnan5/hermes-whatsapp-voice) 搬到 DSH 的插件：
**和 Hermes 里那套一样，两个工具、同一份 sidecar 契约、同一套「没接通就换渠道」的兜底话术。**

- `whatsapp_call_owner` —— 给机主打一通真实的 WhatsApp 语音电话，语音助手实时对话。
- `whatsapp_call_status` —— 某通电话的状态与逐句记录，或者最近几通。

结果会画成原生卡片（`presentationMeta`）：状态、时长、方向，加最后几句对话。

## 为什么是「插件 + sidecar」两层

WhatsApp 的语音要维持一条端到端加密的实时流，还要跑 Gemini Live 的双向音频 —— 这活儿必须由一个长期
存活的进程持有 WhatsApp 的已链接设备状态。DSH 插件是引擎里的 JS 模块，不该扛这个。所以分工是：

```
用户/模型 ──► DSH 工具 ──HTTP──► sidecar（Rust，持有 WhatsApp + Gemini Live）──► 电话
                    ◄── 状态/记录 ──┘
```

插件只做三件事：把工具参数变成一次 `POST /calls`、轮询到「有结果」为止、把结果画成卡片。
音频一个字节都不经过 DSH。

## 需要什么

| 东西 | 说明 |
|---|---|
| sidecar | 来自 [hermes-whatsapp-voice](https://github.com/ashwanthbalakrishnan5/hermes-whatsapp-voice) 的 `hermes-wa-voice` 可执行文件，跑在**和 DSH 同一台**机器上 |
| WhatsApp | sidecar 扫码登录一个已链接设备（那是**机器人自己的号**） |
| Gemini | Gemini Live 的 key，给 sidecar 用 |

## 装

```bash
dsh plugin --profile web add /绝对路径/dsh-go-example-whatsapp-voice
```

然后给 DSH 进程三个环境变量（也就是说，起 `dsh web` 的那个 shell 里要有）：

| 变量 | 默认 | 作用 |
|---|---|---|
| `WHATSAPP_VOICE_SIDECAR_URL` | `http://127.0.0.1:8796` | sidecar 的地址（它的 `HWV_LISTEN`） |
| `WHATSAPP_VOICE_TOKEN` | 空 | sidecar 的 bearer token：它数据目录里的 `sidecar.token` |
| `WHATSAPP_VOICE_OWNER` | 空 | 唯一被呼叫、也是唯一会被接听的号码（国际格式，例 `+60123456789`） |

`WHATSAPP_VOICE_OWNER` 是给人看的：真正的「只呼机主、只接机主」由 sidecar 的 `HWV_OWNER` 强制。

## 模型会怎么用它

```
用户：帮我盯着服务器，挂了就打电话给我
模型 → whatsapp_call_owner {reason: "服务器 502 了，需要你确认是否回滚", details: "…"}
     ← {call_id, status: "in_progress", note: "机主已接听…"}
模型 → whatsapp_call_status {call_id: "…"}      # 挂断后拿逐句记录
```

- 铃响超时（`ring_timeout_seconds`，sidecar 侧配置）＋20 秒内没结果，工具就返回 `status: "ringing"`，
  并告诉模型「再用 status 看一次」—— 不会让工具调用一直挂着。
- `no_answer` / `rejected` / `failed` 都会带一句「换渠道」的提示，和原插件一致。

## 测

```bash
npm test     # 11 条，全部跑在一个假 sidecar 上：不需要 WhatsApp、Gemini、Rust 二进制、也不需要网络
npm run check
```

`npm test` 覆盖：接通、无人接听、超时不死循环、空 reason 不发请求、按 id 查、列最近通话、
sidecar 没起、bearer token、sidecar 报错透传、两个工具注册形状、五种状态的卡片都能被
`view.schema.json` 校验通过、卡片文案与文本一致。

## 边界

- **只呼机主**：`reason` 里写谁都没用，号码来自 sidecar 配置。
- **音频不落 DSH**：插件只读状态与文字记录；录音（`record_calls`）留在 sidecar 的数据目录。
- **没有 sidecar 就没有工具能力**：没起 sidecar 时工具会返回一条明确的错误，而不是静默失败。
