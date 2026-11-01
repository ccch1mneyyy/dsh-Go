# 鸿蒙本机工具能力只读审查（2026-11-01）

本轮未修改主资产、未打包、未操作设备。结论是静态调用路径审查，不代替实际Agent工具目录枚举。检查对象：当前仓库harmony/plugins/dsh_runtime_ohos、固定dsh-rc4-native-stage中的原预设，以及同版本deepseek-harness源码。

## 已确认边界

- assets/subprocess-ohos-loader.mjs:16只允许cwd `/`；assets/subprocess-ohos.mjs:143起只接受4项固定PTC启动argv、特定stdio/heap参数；32行resolveExecutable只接受node与固定入口，末尾spawnTerminal明确抛OHOS_TERMINAL_UNSUPPORTED。
- scripts/patch-ptc-runtime.mjs:18–24说明隔离绑定、空环境、不保留跨调用内存；拒绝executionMode非per-call、非node-script，workerCwd固定 `/`。这是一次性程序运行能力，不是任意shell/终端/持久Python或Node REPL。
- 宿主workspace工具可以绑定调用，不因此允许子进程直接访问宿主工作区。该界限应继续保持。

## 原预设实际注册路径

| 范围 | 声明与执行路径 | 判断 |
|---|---|---|
| standard：bash | dsh-web-app/presets/standard.patch.yml:21，tool-bash仅win32禁用；tool-bash/src/index.ts:34注入shell等，369工具名bash，538–553服务齐全即注册。bash-sandbox继承LocalBashExecutor；bash-local/src/index.ts:259最终subprocess.spawn任意bash argv | 当前OHOS拒绝该spawn。即便注册或resolve成功，也不代表可以执行命令 |
| standard：glob、grep | standard.patch.yml:29 tool-fs-search；tool-fs-search/src/index.ts:71注入subprocess，121–125明确因npm ripgrep存在而无条件注册，145/151注册两工具；search-core.ts:239最终spawn(rg argv) | OHOS的subprocess服务存在足以激活插件，但固定PTC白名单不接收ripgrep。两个工具是最明确的广告能力与执行能力不一致 |
| minimal：持久bash | minimal.patch.yml:34的persistent-shell组，包含pty/terminal-bash/persistent-bash；terminal-bash/src/index.ts:234直接注册后端，189/208调用spawnTerminal；tool-bash-persistent:486直接注册bash | 不支持。也不能把standard的一次性bash与minimal持久bash混为同一实现 |
| 可选terminal bundle | experimental-terminal-bundle/cordis.patch.yml optional-persistent-terminals组；tool-terminal/src/index.ts注册terminal_open/send/read/signal/close/list | 六终端工具属于可选bundle，不是standard默认六工具。若用户启用此bundle，仍会注册却无法spawnTerminal |
| PTC持久模式 | 当前平台注册只配置per-call，派生runtime构造函数拒绝其它模式 | 已有失败边界，不能宣称persistent-in-memory可用；不能以空实现伪造状态延续 |

## 当前生产组合的特殊风险

真实打包映射见package-runtime.py:29：`transport/cordis-min.yml`来自assets/platform-diagnostic.patch.yml；旧work/harmony/runtime-installed里的同名文件是过期材料，不能拿来证明生产能力。

当前platform-diagnostic.patch.yml明确启用bash-sandbox，根tool-bash/tool-pwsh禁用，但没有同步禁standard.config.plugins里的tool-bash/tool-fs-search。agent-preset-registry/src/index.ts:126把record.config.plugins交mountPreset；mount.ts:204–209创建独立PresetTree并加载这些插件。因此不能把根相同id的disabled状态当成子预设已禁。实际是否广告bash仍需在主会话中枚举；glob/grep同样必须在挂载standard之后确认。

## 最小诚实处理方案

1. 在OHOS平台派生配置里禁用无法执行的shell provider（bash-sandbox/pwsh-sandbox等）以及根tool-fs-search；在实际preset-standard.config.plugins中禁tool-bash、tool-pwsh、tool-fs-search。保留其余已验证文件工具和PTC绑定，不加假shell，不更改Android配置。
2. minimal禁整个persistent-shell组；可选bundle禁optional-persistent-terminals。若自定义预设重新加入这些插件，平台能力过滤仍需阻止广告；不以改process.platform冒充win32来切换（那只会错误启用pwsh）。
3. 必须使用原Loader已证配置合并方式修改预设子行；不能随意用短config.plugins数组覆盖全部原配置，也不能仅追加根同名id期待它影响独立树。更稳妥的持久能力方案是在相关provider暴露显式能力并由插件注册前判断；当前最小方案可用平台派生预设+实际目录验收，但需说明自定义插件的界限。
4. tools.restrict是每Agent限定，core/tools/src/index.ts:162–182要求scoped context且只能列已知工具名。可在所有会话/子代理已挂载后由统一平台入口限制已存在的不支持名称；不能在root全局调用，也不能把未知名称直接传deny（会抛错）。该方式只有覆盖所有创建路径才可作为平台保证，不能只限制测试Agent。
5. 不要整体禁jobs、subagent或workflow：它们也承载非shell工作，单凭shell不能执行不足以断言全部不支持。对未验证能力继续标待验，禁止将注册成功当功能通过。

## 验收要求

- 全新standard Agent无任何测试allow-list，枚举最终模型工具schema与PTC绑定，确认不广告bash/pwsh/glob/grep；read/write/edit等按真实功能结果保留。
- 切换minimal、可选终端bundle和自定义预设，验证未出现不可执行的持久bash或terminal_*；重复创建会话与subagent，验证没有遗漏路径。
- 从工具目录移除不代表功能补齐：PR与界面能力提示须明确“本机一次性隔离程序+已验证宿主工具；当前无任意shell/终端/ripgrep”。如果用户目标是与Android完全对齐，这些仍是未完成差距。
- 未来真正提供相应官方平台实现后再启用，并逐项用真实命令/文件结果验收，不能将错误文本或空结果伪装成功。

## 已验证的最小生成补丁契约

`tests/runtime-lifecycle/capability-patch-contract.test.mjs`直接提取固定官方资产中真实`applyEntryPatches`和`mountPreset`函数测试，四项通过。测试不写资产或Android配置。

真实`applyEntryPatches`只递归`entry.group && Array.isArray(entry.config)`，不进入普通preset对象的`config.plugins`；且`target.config = value`为整体替换，不会深度合并。因此精确方案是：

- 从最终原始预设行复制**完整config**，保留id/order/name/description等字段。
- 对复制的完整plugins列表只给不支持行加`disabled: true`；group中的config列表同样递归。所有其它行、顺序和`!!js`表达式保持原样。
- 生成`{id: 原preset行id, config: 完整新config}`，另生成根provider/tool禁用行。不要用仅三个禁用插件构成的短plugins列表，避免丢失其余工具与配置。
- 平台选择仅OHOS显式运行路径启用，非OHOS返回空补丁；测试验证输入对象不被修改且Android路径序列化完全相同。
- `!!js`在生成时须保留原Loader表达式契约。固定Loader的isJsExpr直接识别带`__jsExpr`的对象，因而JSON派生配置可以保留该对象形式；不可把它降成普通字符串或提前按Windows宿主求值。当前契约测试保留包装对象但未覆盖生产文件序列化再加载，这仍需接入时补验。

四项测试覆盖：根禁用不能渗入preset（反例）；完整config复制后根与子行同时禁用；Android与输入不变；原mountPreset函数确实把已禁列表传入新独立树。

**测试界限**：最后一项使用真实mountPreset函数，但树、审计和预处理是观察桩，只验证边界参数传递，未真实激活插件。它不能证明最终模型工具目录或PTC绑定已经正确。后续仍需真实standard挂载、模型schema和PTC绑定枚举，以及自定义预设/新会话/子代理路径实测。当前本轮没有向生产加入禁用规则。

运行方式：`node harmony/tests/runtime-lifecycle/capability-patch-contract.test.mjs <固定资产node_modules目录>`。测试路径通过参数指定，未把本机绝对路径写入测试代码。


## A/B方案比较与独立准备（未接入118资产）

建议对一次性shell与ripgrep使用方案B，对terminal/persistent保持明确平台组合禁用。

| 方案 | 优点 | 限制 |
|---|---|---|
| A：完整复制最终preset config/plugins后禁项 | 不改变原工具模块；原applyEntryPatches契约已验证 | 要处理每个预设和用户修改后的最终组合；复制/序列化整份用户插件配置有不必要接触凭据的风险；只处理官方standard会漏自定义预设；需保留所有表达式及字段 |
| B：真实工具apply入口能力guard | 三个入口各一行；只读当前scope的subprocess能力标志，不读用户config、凭据、环境；任何预设包含同插件都受约束；marker缺失/false保持原行为 | 必须让所有这些插件引用派生模块；仅官方preset改name仍会漏自定义import。需要平台模块解析覆盖或固定已校验安装资产派生补丁；运行中provider能力变化要重挂插件，单次apply guard不会自动改变已注册工具 |

`plugins/dsh_runtime_ohos/scripts/patch-tool-capabilities.mjs`已独立准备，尚未接入package-runtime或任何生产启动路径。只接受三个固定模块及唯一锚点，源码不匹配或重复修改明确拒绝；仅在入口插入：

```js
if (ctx.get("subprocess")?.ohosIsolatedPtc === true) return;
```

使用ctx.get是因为原bash/pwsh inject不包含subprocess，保持原inject时缺失能力不能通过属性访问造成初始化异常。标志只来自正式OHOS provider，不以process.platform猜测；不改变Config/export/其余函数/第三方许可。

固定资产精确锚点：dsh-tool-bash/lib/index.js:340与dsh-tool-pwsh/lib/index.js:313的`function apply(ctx, config = {}) {`；dsh-tool-fs-search/lib/index.js:1241的`async function apply(ctx, config) {`。guard在配置读取、prompt注册和工具注册之前。

`tool-capability-guard.test.mjs`加载真实三个工具模块（临时副本仅改import解析到固定原依赖）、原Cordis Context、原SystemPrompt和原ToolsService。提供仅用于注册的shell/工作目录服务对象，禁止执行子进程；**不用tools.restrict**。实测：

- marker=true：真实tools.schemas()与tools.sdkSchemas()均无bash/pwsh/glob/grep。
- marker缺失或false：完整schema及PTC SDK schema与未修改原模块深比较相等，四名称为bash/glob/grep/pwsh。
- 原inject和export键集不变、原文件未写；未知模块、重复补丁、源码锚点变化均拒绝。

3项测试通过。此测试比前一边界观察桩更进一步，是真实注册/模型schema/PTC SDK投影，但仍是宿主注册夹具，**尚未挂完整standard预设、完整Agent生命周期，也未替代最终真机标准会话验收**。原dsh-rc4固定ToolsService提供sdkSchemas而非较新源码的definitions，测试已按实际版本调整，不能从新checkout API臆测固定资产接口。

后续平台接入须采用白名单固定文件、原摘要校验、同源补丁和归档摘要更新；不得为找预设而读取用户凭据，也不得只在测试Agent上隐藏工具。terminal/persistent模块继续从root/preset/optional bundle明确禁用，保留真实不可用声明。正式验收仍需不restrict read/write的standard模型schema/PTC绑定枚举、新会话/子代理/custom preset覆盖，以及Android/远程markerfalse回归。

## 119候选生产接入（待真机）

已接入方案B：`probe-bootstrap.mjs`在CLI模块导入前执行`installOhosToolCapabilities(installed)`；`package-runtime.py`加入helper与安全能力枚举探针。当前改动不改变App宿主、Node库、NoWatch或Android配置。

范围扩展为七个固定官方模块：一次性bash、pwsh、fs-search；tool-terminal；tool-bash-persistent、tool-pwsh-persistent；terminal-bash后端。各模块只在原apply最前增加同一个能力guard，原Config/inject/export与其余实现保持。因而不需要复制用户preset配置，也不需要短数组覆盖；标准、最小、自定义组合引用这些同位置模块都会经过同一入口。终端registry可存在，但OHOS后端和工具不登记，不伪造终端。

安装器仅process.platform为openharmony时工作；白名单七个文件逐个核固定原SHA256或精确已补丁SHA，并先完成全部校验再写入。未知源码、部分自行改动、重复异常guard均拒绝；二次启动幂等。它不扫描用户插件/配置、不会读取模型密钥。其他自定义模块如果自行实现或绕过这些入口，不属于已验能力，不能因此宣称平台支持shell。

最新`tool-capability-guard.test.mjs`5项通过：前三项原工具注册；持久shell/终端真实插件与ToolsService注册过滤、markerfalse完整schema一致；七文件摘要安装器首轮/二轮/篡改拒绝、Android路径无文件访问。真实终端后端注册的宿主夹具为观察对象，未启动PTY；最终标准与最小预设仍待真机。

`assets/tool-capabilities-probe.mjs`导出`runToolCapabilitiesProbe(ctx,{fixtureParent})`。要求调用方提供专用新测试目录；测试创建新standard和minimal Agent、仅presentAs('ptc')，没有tools.restrict或allow-list。分别读取真实`schemas(agent)`与`sdkSchemas(agent)`，拒绝任何bash/pwsh/glob/grep/terminal_*，确认目录非空且standard有read/write；仅保存固定布尔、计数、白名单禁项，绝不输出完整schema中的用户描述、路径或凭据。全局测试期间阻断llm/stream，结束dispose所有新Agent并移除监听。

父代理需在显式一次性验收入口调用该函数并保存安全报告。`CAPABILITY_PROBE_OK`且disposeConfirmed才表示本次真实预设目录通过；它仍不意味着缺失shell/终端/ripgrep功能已补齐。119安装前后须保留文件工具118的验收结果并复验组合没有回归。

## PTC枚举语义复核

固定rc4 ToolsService的`schemas()`是可见注册目录，PTC模式还会加入run_code；它不是最终模型wire schema。`wireSchemas(agent).schemas`才将模型入口折叠为唯一run_code，`sdkSchemas(agent)`才是可绑定能力。新版探针分别记录registeredCount、schemaCount、bindingCount及各自禁项列表，要求ptcWireOnly，并只从SDK判断read/write/edit/read_image。

minimal原预设禁用read/write/edit，只开启readImage；原tool-fs还要等attachments服务才注册read_image。因而移除持久shell后minimal最多保留图片读取及实际继承能力，不能被描述成完整代码终端；若SDK空则CAPABILITY_EMPTY_PRESET，若无read_image则CAPABILITY_MINIMAL_IMAGE_MISSING。standard要求SDK read/write存在。

最新宿主测试6项通过。新增真实ToolsService/createScope/presentAs('ptc')验证：空绑定仍有1个run_code模型入口；read/write出现于SDK且wire仍只有run_code；移除它们后只注册read_image可明确识别minimal有限能力。测试没有调用restrict，没有执行模型或文件工具；完整原预设真机枚举仍待119。
