# 原版 Flutter 页面的鸿蒙宿主

本工程复用 `app/lib` 的原版界面与协议，通过鸿蒙平台插件补齐系统能力。
本机 DSH、隔离任务与文件工具已在 MatePad 上通过下述限定范围的验收；适配仍在收尾，不代表与安卓版全部功能一致。

## 工具链与源码入口

- Flutter-OH 固定提交：`650641656fef1d0578f0bc1ed8f7a35087fc99f3`，版本 `3.47.7+ohos-0.0.1-pre`。
- 当前真机与构建采用 HarmonyOS API 26；未验证更低版本。
- 安全存储：`entry/src/main/ets/plugins/DshSecureStoragePlugin.ets`，使用 HUKS。
- 文件和图片：[`dsh_attachment_picker_ohos`](../../harmony/plugins/dsh_attachment_picker_ohos)。
- 安全粘贴：[`harmony_secure_paste`](../../harmony/plugins/harmony_secure_paste)，配合[固定框架补丁](../../harmony/tooling/secure-paste-sdk-patch)。
- 五个 Pub 依赖的固定补丁：[离线重放工具](../../harmony/tooling/replay-pub-patches)。
- 四个官方鸿蒙后端的固定源码和补丁：[后端重放工具](../../harmony/tooling/replay-ohos-backends)。
- Windows CLT 启动器递归报错时：[最小修复](../../harmony/tooling/ohpm-windows-launcher)。

插件由工具生成注册代码；自有安全存储桥在 `EntryAbility.ets` 注册。
签名配置、设备登记、私钥和密码由开发者在本机配置，不纳入源码。

## 默认图标

应用、桌面入口和启动图默认使用 `AppScope/resources/base/media/dsh_launcher.png`，逐字节复用安卓原版 `android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png`（192×192，默认雾蓝）。夜幕、霜白、墨三种备用图标也复用原PNG，通过API26的 `alternateIcons` 与 `DshLauncherIconPlugin.ets` 接入原 `dsh/launcher_icon` 选择契约。桥接只返回实际系统状态，设置后读回确认；恢复雾蓝会撤销备用图标。固定测试见 [`launcher-icons`](../../harmony/tests/launcher-icons)。2026-10-30原生构建18.6秒成功并签名安装，MatePad真机从原版设置依次切换夜幕、霜白、墨、雾蓝，桌面与Dock图标均实际变化，点击图标可返回原页，最终恢复雾蓝。

没有重新设计、缩放或改版权；四份图标资源字节与安卓原图一致，品牌素材继续适用根目录 [ASSETS.md](../../ASSETS.md) 的原有条件，不属于AGPL代码许可。系统桌面mask可能因设备或主题而不同；未取得形状时返回未知，不编造与安卓相同的裁切。应用进程重启后夜幕选择保持已通过，再次恢复雾蓝。其他设备、低于API26以及设备重启后的图标持久性尚未验证。

## 已验证的范围

MatePad 真机已验证原版页面启动、HUKS 存储、SSH 测试主机连接与重启重连、
内嵌网页切换、文件附件、相册选图、拍照回传与取消，以及标准输入框长按安全粘贴。
附件测试只检查选择和界面回传，没有发送给模型。网页加载不代表账号登录和所有网页功能通过。

## 本机模式验收边界

2026-11-01，原版 Flutter 页面连接本机 DSH 的认证交换、会话列表、事件通道、创建与改名，以及停止、再次启动和冷启动读回均已通过。Node 24.2.0 使用 `--jitless --wasm-jitless`，Wasm 固定计算及未经替换的原 `globalThis.fetch` 回环请求已通过，主引擎使用同一运行库，不再保留临时 fetch 替代。

隔离 PTC 已验证独立 UID、固定源码只读 FD、双向协议、并发任务、输出背压、取消、异常退出及回收。真实标准预设的 `run_code` 经原工具绑定完成两个工作区的写入和读回；只读、目录外、跨工作区和执行中撤权均按原权限契约拒绝或取消。会话及文件的新目标发布使用排他原子发布，不能覆盖已有目标。任务的实际系统工作目录为 `/`；它不能直接访问宿主工作区路径，文件操作由宿主绑定按策略执行。

验收构建 119 还通过了无 Key 的真实 agent loop 对话：全新测试上下文注册仅用于验收的回环模型适配器，经过本地 HTTP 流式响应、原会话事件与持久化；119b 完全停止后用同一测试目录冷启动，读回相同用户和助理消息。它验证了真实 agent/model 协议与持久化，**不是外部供应商或付费模型调用，也不是原 Flutter UI/RPC 模型对话的完整验收**。固定测试文本未使用用户凭据。

验收脚本及独立测试包注入方法位于 [device-fixtures](../../harmony/tests/runtime-lifecycle/device-fixtures/README.md)，不进入正常运行资产，临时导出 Ability 与旧 Runner 也已移入测试夹具。清洁正常包 121 已通过认证、会话列表、标题持久化和文本附件上传；123 修复停止后的白屏，原引擎页停止确认旧进程退出，再次启动页面可见且新进程认证、列表与标题检查通过。123 与 127 完整 force-stop 后冷启动的认证、列表、事件通道和固定标题核验已通过；详见[本机验收摘要](../../harmony/docs/local-mode-validation.md)。

用户授权后，正常包 127 已通过原凭据服务使用已保存 API Key，完成一次 `deepseek-official/deepseek-flash` 的真实短回复。原 RPC/mux 流式事件、历史落盘、完全停止后的冷读，以及原 Flutter 页面显示均已实际通过；诊断未读取或输出 Key。该结果不替代账号模型生成验收。

原账号登录也已实际通过：原 Flutter 页面打开 DeepSeek 官方网页，用户完成网页交互并返回应用后，Host 的 PKCE 回调交换及凭据提交到达 succeeded/credential-stored；个人资料、余额及账号模型目录可用。恢复无诊断正常包 130 后完全停止再冷启动，登录态与上述查询均保持。未读取或输出账号 token，未注销账号，尚未发送账号模型生成请求。浏览器前台期间曾出现本机接口超时，不据此承诺后台常驻或超长网页登录。

## 构建顺序

1. 使用上述固定 Flutter-OH 工具链，重放 Pub、鸿蒙后端与安全粘贴补丁；重新解析本机依赖覆盖，不提交含绝对路径的锁文件。
2. 按 [Node 重放材料](../../harmony/tooling/node-runtime/drumbrake-compressed/README.md) 准备同源 Node、头文件和配置，再按 [原生桥构建](../../harmony/tooling/NATIVE-RUNTIME-BUILD.md) 生成主引擎、五个 PTC 桥及排他发布库。桥接库已重放；干净 Node 长编译尚未重新完整执行，不能将两者混同。
3. 先按[清洁资产导出说明](../../harmony/tooling/prepare-dsh-assets/README.md)校验官方 APK 并导出固定 rc.4 输入（已实际重放 14576 个原文件、12 个命令映射，不使用用户安装目录），再用 [`package-runtime.py`](../../harmony/plugins/dsh_runtime_ohos/package-runtime.py) 装配固定 DSH 资产，将匹配的原生库和资产加入本工程。打包输入、平台补丁和第三方许可须一起保留；生成包不提交源码。
4. 在本机配置签名，以 `app/ohos` 为鸿蒙宿主构建、签名并进行真机验收。不要使用根 `harmony` 早期 ArkTS 工程替代此入口。

## 尚未覆盖

- 重置、安全/自动安全模式与 LKG 恢复不支持；变更操作明确返回不支持，不伪报恢复或清理成功，不删除用户数据。

- 一般 shell、终端、外部命令、任意缓存 `.node` 扩展及持久 PTC 尚不支持；能力声明已按平台收敛，不能把隐藏不支持工具称为已经实现。
- 账号模型生成、快捷键粘贴及其他自定义编辑入口仍需验收；真实模型回复结果仅覆盖上述 API Key 短回复。
- 语音、手机操控、后台运行策略，以及其他设备和低于 API 26 的系统未完成对齐验证。
- 九个第三方依赖虽已有固定离线重放材料，但当前调试环境不等于干净机器完整构建证明。签名、设备标识、生成 HAP、私钥与本机路径锁文件不属于提交内容。
