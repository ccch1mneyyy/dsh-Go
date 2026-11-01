# 核心插件恢复审查（固定 rc4，2026-11-01）

初次审查只读生产配置；后续120恢复repeat、127恢复settings-controller、128恢复account-controller的配置变更分别记在下文。宿主回归未构建、签装或读取用户配置/凭据。测试使用固定发行资产，不能用较新源码 checkout 的 API 推断本包。

## 历史证据边界

旧会话完整阅读台账 `session-full-reading/reading-049-095.md` 第073、077、078轮显示：禁项来自批量裁剪、把包名当id、错误副本打点与JS语法损坏。旧“registerPiAiFlows卡死”没有有效独立对照；源码函数只注册授权回调，并不运行登录。不能沿用此结论认定平台不兼容。

## 实际配置与建议

| 项目 | 固定包事实 | 下一步 |
| --- | --- | --- |
| timeout | base/cordis.patch.yml:408 实际id为 `timeout-policy`；平台的 `tool-call-timeout-policy` 禁项未命中 | 已存在，勿重复挂载；验证取消/超时即可 |
| repeat-tool-reminder | base:448真实同名id，当前确实禁用；纯工具事件/内存状态 | 建议120恢复；本轮等待父通知后才改 |
| agent-tool-presentation | PTC preset:123 实际id `tool-presentation`，配置mode:ptc；根平台 `agent-tool-presentation` 禁项未命中 | 保留preset作用域；不得根挂载，否则presentAs缺scope会拒绝；standard与PTC是不同预设，不应以探针显式presentAs推断standard默认呈现 |
| settings-controller | web:150实际同名；原先禁用使credentials namespace也缺失，127仅恢复该项；真实settings read/write返回均redactSecrets:true | 原Controller的credentials describe/set/unset宿主RPC回归通过；openSettingsDocument仅显式RPC时调用编辑器，平台可保留明确失败，不代表已有原生编辑器支持 |
| llm-pi-ai | base:135真实同名，当前禁用；空providers注册目录/授权回调，不发模型请求；有配置才注册route | 旧卡死证据无效，可独立恢复验收；不是DeepSeek官方API-key适配器的前提 |
| DeepSeek官方API-key | base:525 id llm-deepseek，模块dsh-llm-deepseek-api-key，当前平台未禁 | 已做真实空凭据注册验证，无需开启pi-ai才能恢复 |
| DeepSeek账号平台 | base:120实际id deepseek-account，平台deepseek-account-platform禁项未命中 | 不能称被禁，也不能未经登录实测称账号方式可用 |
| account-controller | web:147实际同名，原先禁用；原类注入deepseekAccount、agents并挂account namespace | 128仅恢复此项；宿主夹具通过，随后真实浏览器登录提交、资料/余额/模型目录及130正常包冷启动登录保持通过 |
| compaction-basic / pruner | web原组合已主动禁根compaction-basic；standard/minimal有独立作用域compaction；pruner真实id tool-result-pruner | 保留上游作用域设计，不以根disabled批量恢复导致重复 |
| goal-round-driver | 真同名禁项；只对armed active目标，在idle时flush后启动followup，涉及自动多轮 | 单独测轮数限制、停止及持久化后再恢复，不能与纯提醒混为一类 |

网页UI插件可继续由Flutter界面替代；系统shell、terminal、office转换、原生编辑器不是恢复注册就可执行。

## 本轮宿主验证

脚本：工作目录 `core-restoration-check.mjs`，运行退出0。

- 真实 Cordis Context、原 LlmRuntime、原 DeepSeek API-key 模块：注册 `deepseek-official` adapter和可配置目录成功。
- 提供全新空 launchEnvironment，credentials.resolve为拒绝读取spy，fetch为拒绝调用spy。结果 credentialReads=0、requests=0。未调用listModels/discover/connect/auth，故不证明真实模型请求成功。
- 原 timeout apply：10ms期限、30ms固定工作得到超时结果，执行上下文恢复原signal。
- 原 repeat apply：固定工具参数第三次得到一条提醒，用户消息后清链。
- timeout/repeat是直接原apply及事件捕获夹具的行为回归，不是完整会话真机验收。

## 真机恢复门槛

先对本次确定命中的repeat解除禁用，真实会话验证工具链仍运行且提醒不破坏PTC。timeout本来已启用，需验一次真实可取消工具。127的settings恢复仅有下文宿主回归，原App同步及真实模型调用仍由设备验收确认；pi-ai继续单独验证，不以注册成功宣称其路由可用。

## 120 配置落地

已获父确认119归档完成后，仅将 `repeat-tool-reminder.disabled` 改为 `false`。其余禁项未变。可复跑回归脚本已加入 `harmony/tests/runtime-lifecycle/core-restoration.test.mjs`，参数为固定发行资产的node_modules目录；本轮运行退出0，输出与上节一致。真实120平板复验由父进行，尚不能据宿主测试称真机提醒已过。

### standard 的实际默认呈现

固定 `dsh-web-app/cordis.patch.yml:32–38` 用 `process.env.DSH_TOOLS_MODE` 配置全局tools.mode，明确未设置时保持schema默认native。`dsh-tools/lib/index.js:2763`默认native；`wireSchemas`在native时返回全部可见原工具schema，在ptc时才收敛为run_code。

standard.patch.yml没有tool-presentation插件；ptc.patch.yml:123才显式声明mode:ptc。当前生产bootstrap/native/App入口未设置DSH_TOOLS_MODE。因此默认standard应保持native直接read/write等工具，不会因为禁shell而自动变成PTC，也不存在所谓bash presentation。此前探针显式presentAs('ptc')只证明PTC可用，不代表默认standard是PTC。建议保留原版默认，需run_code时使用原PTC预设；不要为让探针结论看似一致而无必要改变所有standard会话。

## 127 恢复凭据 RPC 所需的 settings-controller

父设备验收确认126的模型目录RPC能够快速返回，但缺少DeepSeek官方组，原credentials/describe RPC不可用。固定`dsh-api-settings-controller/lib/index.js:374–377`证明：SettingsController构造不仅注册settings命名空间，还通过`ctx.plugin(CredentialsController)`挂载credentials命名空间。平台`settings-controller.disabled:true`因此同时裁掉Flutter同步已有App Key所需的原`credentials/set`入口。`app/lib/state/connection_state.dart:116–121`的`_pushKey`捕获同步失败而不提示，不能凭App已有Key推断Host已收到Key。这是已定位的组合缺口；不能据此归因DNS、TLS、匿名ID、账号控制器或API-key适配器。

本次只把`platform-diagnostic.patch.yml`中`settings-controller.disabled`改为`false`，未改account-controller、llm-pi-ai或DeepSeek账号组合。原Controller在构造时只保存`openNativeTextFile`函数引用；`prepareDocument`与原生编辑器调用都位于显式`settings/openSettingsDocument`方法内，恢复注册不会启动浏览器或编辑器。平台不支持时保留原错误，不伪造打开成功。

可复跑：`node harmony/tests/runtime-lifecycle/settings-controller.test.mjs <固定发行资产node_modules绝对路径>`。测试使用真实Cordis Context、原TypertRegistry、固定包生成TYPERT描述、原Gateway RPC和原SettingsController；settings/credentials提供者均为内存安全夹具，不加载credentials-local、不解析任何用户凭据。旧配置先因`disabled:true`断言失败，恢复后退出0：

- 原settings与credentials命名空间均实际挂载；credentials/describe只返回configured/source/writable，夹具故意附加的value被原Controller丢弃；resolve调用数为0。
- 固定虚拟值经原credentials/set/unset进入内存提供者，状态变化准确，RPC返回不含值；非法ref按原gateway/bad-request拒绝。
- settings describe及update/replace/mutate返回均要求提供者接到`redactSecrets:true`，原Controller字段投影去除描述及secret状态中额外的夹具值。
- 提供者拒绝保留原credential/rejected、settings/rejected分类和固定诊断；wire仅code/message/details，不带异常cause或任意附加value。原Controller会原样保留提供者message，此测试不宣称会清洗任意包含秘密的错误message。
- 启动及上述RPC均未调用prepareDocument/编辑器；只在显式openSettingsDocument调用后各调用一次，并返回原gateway/internal失败。

上述宿主结果只证明恢复配置 RPC 的契约。后续正常包 127 已独立验证 App 同步已存 Key、官方目录、一次真实短回复、冷启动历史与原 Flutter 显示，详见本机模式验收摘要；诊断未读取实际 Key。

## 128 单独恢复账号控制器

用户明确要求尝试账号登录后，本次仅将`account-controller.disabled`改为`false`。原base:117–123的authorization与deepseek-account provider、base:528–529的llm-deepseek-account保持原组合；未添加Node原生浏览器桥，未全开其他禁项。

固定`dsh-deepseek-account-platform/lib/index.js:824–881`由startSignIn创建attempt并启动原authorization flow；`:967–1093`用Node内建crypto生成PKCE/state，在已有webServer注册`/oauth/callback`，原fetch请求平台auth_init、收到浏览器回环后auth_exchange，再通过原credentials.modifyRecord提交grant。该主链没有Linux浏览器命令、spawn或TTY依赖。平台账号、密码、验证码和审批均在平台网页中由用户本人完成，Host没有独立验证码API。

客户端已有适配入口：`app/lib/state/account_api.dart:356–361`传本机callbackOrigin及loginSource:web；`account_state.dart:57–70`使用现有url_launcher尝试inAppBrowserView与externalApplication。是否需要继续修OHOS浏览器边界，以实际打不开或回环失败为证；不能因Host注册恢复就假定登录已完成。默认desktopPlatform:null保留原web客户标识，不伪装mac/win。

可复跑：`node harmony/tests/runtime-lifecycle/account-controller.test.mjs <固定发行资产node_modules绝对路径>`。测试使用真实Cordis Context、原TypertRegistry、固定包生成TYPERT、原Gateway与原AccountController；账号服务是内存安全mock，不挂真实凭据或平台网络。旧配置先因disabled:true失败，恢复后退出0：

- getState及原account/watch流正确传递安全状态；初始credential-stored夹具保留，不会自动signOut。
- startSignIn传递原client、callbackOrigin和web参数，cancelSignIn传递attemptId，状态从waiting-browser到cancelled。
- Host私有resolveToken/getPlatformSession没有Remote导出，尝试远程调用均返回gateway/invocation-unavailable；tokenReads=0、signOuts=0，测试输出只含检查结果。
- 没有运行既有account_live_test；该测试存在初始已登录后主动signOut的行为，不适合直接用于可能已有账号的设备。

上述宿主测试只覆盖控制器组合与转发协议。后续真机已从原 Flutter 入口打开官方浏览器，用户完成网页交互并返回应用后，Host 到达 succeeded/credential-stored，资料、余额和账号模型目录通过。移除临时诊断后的正常包 130 完整冷启动仍保持登录并通过上述查询。首轮 protocol 失败及浏览器前台 RPC 超时如实保留；不把成功复测归为已确认的后台修复。未读取用户 token、未主动注销，账号模型生成尚未验证，API Key 成功不计入账号推理验收。

固定协议无refresh_token/auth_refresh；auth_init的expires_in属于attempt期限。原账号token失效由401触发rejectToken/expireCredential，删自家grant并发session-expired，然后重新登录。凭据record使用原wx锁文件及普通异步rename覆盖更新，保留其语义，不改成RENAME_NOREPLACE。
