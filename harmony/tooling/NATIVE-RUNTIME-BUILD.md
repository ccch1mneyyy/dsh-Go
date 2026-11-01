# 主引擎与隔离PTC桥的可重放构建

本页列出13个生产库和资产zip的构建顺序。Node有固定源码补丁及配置重放材料；固定 DSH 资产已提供[官方 APK 清洁导出工具](prepare-dsh-assets/README.md)，但仍不能宣称一条命令从干净机器重建并验收 HAP。旧`node-runtime/README.md`的lazy-Undici非压缩方案是历史阶段，不能用于这里的正式Wasm/PTC组合。

## 输入和ABI

- 官方OpenHarmony CLT 26.0.0.851、API26、LLVM19.1.7，目标`aarch64-linux-ohos`。
- Node基础版本v24.2.0，commit `591ba692bfe30408e6a67397e7d18bfa1b9c3561`，另需已应用同一轮鸿蒙/DrumBrake补丁的公开头。
- 当前已验收Node库SHA256：`b2c73a809530bb0e83b1b87797063da65c10a11c49dedd488698a6bb83ed4cb5`。
- 配套真实构建config.gypi SHA256：`94ed1adbbaad899930b13555bc754dd73a166a663a8d7af5e64359b764f4dfe3`。必须用构建产物保存的配置，而不是另一源码副本内旧的非压缩config.gypi。
- 真实C++ ABI宏：`V8_COMPRESS_POINTERS`、`V8_COMPRESS_POINTERS_IN_SHARED_CAGE`、`V8_31BIT_SMIS_ON_64BIT_ARCH`、`V8_EXTERNAL_CODE_SPACE`、`NODE_SHARED_MODE`、`NODE_USE_V8_PLATFORM=1`。脚本默认这六项，拒绝空列表或不同宏集。
- 同一config本身不能证明库/头相符；还须核Node库、头、补丁清单来源。脚本记录各自摘要，不通过库文件名推断兼容。

主进程使用`node::Start`，固定参数`--jitless --wasm-jitless`。隔离PTC的`ptc_embed.cc`使用公开嵌入API及`kNoStdioInitialization`（避免独立UID继承socket上的初始化限制），保留真实stdio，另启用`kDisableNodeOptionsEnv`；它依赖相同V8压缩ABI，不能只换libnode而不重编桥。

## 命令

在仓库根目录运行PowerShell，先将参数设为实际工具链和已核输入路径；输出应选独立D盘work目录，不直接覆盖App libs。

```powershell
$NativeSdk = 'D:/工具链/openharmony/native'
$NodeSource = 'D:/构建/node-v24.2.0'
$NodeLibrary = 'D:/构建/install/lib/libnode.so'
$NodeBuildConfig = 'D:/构建/artifacts/candidate-config.gypi'
$OutputRoot = 'D:/Codex/work/native-replay'

./harmony/tooling/build-main-runtime.ps1 -NativeSdk $NativeSdk -OutputDirectory "$OutputRoot/main"
./harmony/tooling/build-ptc-task.ps1 -NativeSdk $NativeSdk -NodeSource $NodeSource -NodeLibrary $NodeLibrary -NodeBuildConfig $NodeBuildConfig -OutputDirectory "$OutputRoot/ptc"
./harmony/tooling/build-publish-addon.ps1 -NativeSdk $NativeSdk -NodeSource $NodeSource -NodeLibrary $NodeLibrary -OutputDirectory "$OutputRoot/publish"
```

`build-ptc-task.ps1`会从仓库固定`assets/ptc-loader.cjs`重新生成`native/ptc_loader.h`；该文件是确定性引导字符串，不含本机路径。五个PTC库为task/child/shutdown/exit/embed。`libdsh_ptc_embed.so`是生产依赖，不能随旧probe一起删除。

构建使用`-Wall -Wextra -Werror`及`--no-undefined`。主入口和PTC脚本检查AArch64、SONAME和所需入口/依赖，写ELF报告和无本机绝对路径的`build-provenance.json`；publish脚本检查Node依赖并写`build-result.json`。PTC Node桥必须显式依赖`libnode.so`，不得链接ArkTS的`libace_napi`；只有父NAPI任务控制器使用ArkTS NAPI。

历史probe/launcher构建脚本和runtime_launcher.c已移出仓库至开发工作区归档；不再作为生产构建入口。当前主入口只由build-main-runtime.ps1生成。

这些脚本不会签名、安装、自动复制App库或修改用户数据。成功产物中的`verifiedOnDevice:false`表示这次构建尚未验收，不能因编译成功更改为true。

## 已重放结果

2026-11-01在独立输出目录执行了上述主入口及五PTC库脚本。使用固定CLT、B2C库及配套头/config，六个产物与此前已验收桥逐字节一致：

| 文件 | SHA256 |
| --- | --- |
| libdsh_runtime.so | 884bb9c5b45b5486a73b0f3ce78ddb31e7b18e7c651a2850a53d9417f217eaff |
| libdsh_ptc_task.so | 428e681c7b52993d257aa8503abcec4c105a936e518bef0a845346132df7e5c6 |
| libdsh_ptc_child.so | 85ebc47f50ed2500dbbd55ad938af7062788bb9e35d99e0462781a54fe81a3fd |
| libdsh_ptc_shutdown.so | fec8515fa0f011f84771b01c1705f12a1f6338458420ed9f3403292fdc2af137 |
| libdsh_ptc_exit.so | b260c6410b95c5083a329e885cca719444b80d8f734318c0d8765d02d2fe4bfe |
| libdsh_ptc_embed.so | 3c1419d066d3689b257b0cecedd05a7fa2b22b77490386e0b853354b1d94ab17 |

主入口摘要为删除临时验收入口后重新构建的产物；PTC五库与此前产物逐字节一致。这里只证明所列输入下的构建结果，不替代清理后整包真机验收。

## Node源码重放材料

已新增[固定DrumBrake重放目录](node-runtime/drumbrake-compressed/README.md)：成功候选全量10文件patch、逐文件官方前/实际镜像后摘要、8个原版关键文件核对、完整去路径配置、三份许可、准备/配置/构建命令。已在干净官方archive应用并重放configure，完整配置仅安装前缀不同。仍未新跑干净长make，不能将桥接库逐字节复现扩大为Node新全编产物复现；细节与限制以该目录README为准。

## 最终PR仍不能承诺

- 编译/ELF/摘要通过不能代替正常UI、冷启动、附件、持久化和停止重启真机验收。
- 不承诺一般shell、npm命令、任意缓存.node、persistent PTC或任务直接访问宿主workspace；当前隔离任务OS cwd为`/`，通过真实tools bindings按策略访问工作区。
- 不承诺完整Android功能一致、后台常驻策略一致、所有系统版本兼容或已验证付费模型；无Key工具验收没有调用模型。
- 不提交私钥/签名/设备标识/本机路径锁文件/生成HAP或大型二进制。测试导出Ability与旧Runner已移入测试fixture，不进入生产应用。
- GitHub Contributors归属依赖提交邮箱和维护者合并，PR提交或测试通过都不保证显示。

## 第三方固定来源与13库总顺序

1. 从固定Node官方提交准备源码，按[DrumBrake重放说明](node-runtime/drumbrake-compressed/README.md)应用补丁、configure并构建`libnode.so`。保存真实config.gypi及公开头，勿混入旧非压缩配置。
2. 保存实际Node工具链的`libc++_shared.so`与NOTICE。它来自OpenHarmony Linux LLVM19日构建`20261030_061421`，并非Windows CLT中同名库。归档链接为 <https://cidownload.openharmony.cn/version/Daily_Version/LLVM-19/20261030_061421/version-Daily_Version-LLVM-19-20261030_061421-LLVM-19.tar.gz>，SHA256 `37050052f64241615ffb68cae005ec89193dbacef3a3331ef17709d15dca5d8f`。解开其中`llvm-linux-x86_64.tar.gz`和`ohos-sysroot.tar.gz`；库在`llvm/lib/aarch64-unknown-linux-ohos/libc++_shared.so`，SHA256 `25b5fb98b96b618f3d02e4e52033d5d54a9f4d2ea597102abb69b37e1e8a67b9`。本机已和App产物逐字节核对。Windows SDK库摘要为965803c3…，不得凭文件名替换。
3. 准备require-builtin官方仓库 <https://github.com/deepseek-ai/dsh-node-addon-require-builtin>，checkout固定`a58d3599a2e551d7d706d1ff796c9fd4bbaff63c`（0.1.9），保留LICENSE。准备 <https://registry.npmjs.org/node-addon-api/-/node-addon-api-8.9.0.tgz>，先核tar SHA256 `19b87e2ce3a77fec0121ac97d7db088aae28aacfff481adab50d5f61b70e68f4`，再解包，保留LICENSE.md。
4. flock源码直接使用固定DSH rc4资产中的`opt/dsh/node_modules/@deepseek-ai/node-addon-system` 0.1.2包，保留包LICENSE；`src/flock.c`必须为`c1aa773c7a62b03ce3973156b928f41773fef9407afd79d71b2f625b5616421f`。这是实际已验收的原flock实现，没有改用fcntl。该包源声明位于deepseek-harness仓库`native/system/packages/entry`，但未核独立上游提交，故构建脚本以固定包版本加源码SHA准入，不虚构git版本。
5. 执行以下addon、控制桥以及前文主入口/PTC/publish命令。产物合计13库见表。
6. 先按[清洁资产导出说明](prepare-dsh-assets/README.md)校验官方 Android 1.0.2 APK，使用 prepare.py 导出固定 rc.4 树，再生成 zip，核archive SHA并同步App安装清单版本/摘要；正式HAP才复制13个库及zip、刷新ohpm依赖、构建和本人授权签名。不从旧构建缓存混入测试库。

```powershell
# 延续前文的NativeSdk/NodeSource/NodeLibrary/OutputRoot；以下参数由开发者填实际下载/解包目录。
$RequireBuiltinSource = 'D:/源码/dsh-node-addon-require-builtin'
$NodeAddonApi = 'D:/源码/node-addon-api/package'
$RuntimeAssets = 'D:/资产/dsh-rc4'
./harmony/tooling/build-runtime-addons.ps1 -NativeSdk $NativeSdk -NodeSource $NodeSource -NodeLibrary $NodeLibrary -RequireBuiltinSource $RequireBuiltinSource -NodeAddonApi $NodeAddonApi -SystemAddonSource "$RuntimeAssets/opt/dsh/node_modules/@deepseek-ai/node-addon-system" -OutputDirectory "$OutputRoot/addons"
./harmony/plugins/dsh_runtime_ohos/build-control.ps1 -NativeSdk $NativeSdk -OutputDirectory "$OutputRoot/control"
./harmony/plugins/dsh_runtime_ohos/build-broker.ps1 -NativeSdk $NativeSdk -OutputDirectory "$OutputRoot/control"
python harmony/plugins/dsh_runtime_ohos/package-runtime.py --source $RuntimeAssets --output "$OutputRoot/dsh-runtime.zip"
```

网页18项恢复也沿用上面的唯一packager与平台清单映射；重打前可运行[网页恢复契约测试](../docs/web-ui-restoration.md)。不从旧runtime-installed复制覆盖清单，也不为网页界面生成第二份手工ZIP。

| 产物 | 生成来源 |
| --- | --- |
| libnode.so | Node固定源码、补丁、Linux LLVM构建 |
| libc++_shared.so | 同一Linux LLVM归档，保留NOTICE |
| libdsh_require_builtin.so、libdsh_flock.so | build-runtime-addons.ps1，原生NAPI，显式链接libnode |
| libdsh_runtime.so | build-main-runtime.ps1 |
| libdsh_control.so、libdsh_broker.so | 各自build-control/build-broker.ps1，必须显式输出目录 |
| libdsh_publish.so | build-publish-addon.ps1 |
| libdsh_ptc_task/child/shutdown/exit/embed.so | build-ptc-task.ps1，共5个；embed不能移除 |

两个addon已用上述参数化脚本及B2C Node重新实际编译，与App已验收库分别相同：require_builtin `86ffb28463dbf4134a95cce69d698598a1806740425502b179b8d5faf98e2aa1`，flock `28f9df01b9fa9083132402d068f5a67280e7e2e3230b256bccf40946be4e2645`。脚本保留原始编译参数（原产物无SONAME，不擅自添加），检查AArch64、libnode依赖，复制四份许可证并记录来源摘要。控制桥与broker的显式输出模式也已实际编译通过，均没有自动改写App。

`native/ptc_loader.h`已加入生成项忽略规则；唯一来源为版本控制中的`assets/ptc-loader.cjs`，build-ptc-task.ps1每次确定性重建，不需要提交头文件。

**资产来源重放：** [prepare-dsh-assets](prepare-dsh-assets/README.md) 已补齐官方 APK/rootfs 摘要、原 npm 锁摘要、限定前缀导出和逐文件校验。实际全新目录重放得到 14576 个原文件及 12 个经过目标摘要核对的命令映射；未创建符号链接，也不表示这 12 条命令已可执行。14576 个文件分别与原始 stage 和旧生产输入逐项相等；清洁来源不含旧输入额外的 Windows 测试 addon。不要再使用自己的 runtime-installed 或用户 home 作为公开构建输入。

打包器消费上述清洁输出并加入平台实现，保留第三方许可。归档摘要须实际计算，不照抄历史值。当前生产清单严格核结构、路径与 CLI 入口摘要；不是每次启动全量文件验证。来源导出与打包已经重放。构建 120 的 14587 文件 ZIP 已用于正常 121，通过认证、4会话列表、ready、标题持久化和文本附件上传；正常 123 修复停止后的白屏，并在原引擎页确认旧进程退出、可见地启动不同的新进程，认证、列表和标题检查通过。正常 HAP 无测试 Ability，17 个诊断库已移除；123 整个应用 force-stop 后冷启动的接口核验尚待结果。Node 干净长 make 本轮尚未重新完整执行；[验收摘要](../docs/local-mode-validation.md)区分各项已测范围。
