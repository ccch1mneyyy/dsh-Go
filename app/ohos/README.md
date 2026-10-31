# 原版 Flutter 页面的鸿蒙宿主

本工程复用 `app/lib` 的原版界面与协议，通过鸿蒙平台插件补齐系统能力。
目前仍在开发和真机验收，尚不提供完整本机 DSH 运行环境。

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

## 尚未完成

- 九个第三方依赖已提供可校验的离线重放材料，但生成后的本机依赖覆盖和锁文件仍需按开发环境重新解析，不能直接提交当前绝对路径锁文件。
- 本机 Node 共享库已完成源码构建，修正内置 JavaScript 的行尾导致的生成长度失配后，平板基础文件、加密、随机数、回环 HTTP、进程标题五项通过且正常退出；移除全部启动诊断后已再次真机通过。签名平台扩展和文件锁已通过；真实 DSH 启动还需要当前无 JIT 构建缺少的 WebAssembly 网络解析能力，正在构建解释器候选，尚未通过完整本机 DSH 启动验收。
- 原版的 Linux 工作目录、终端、原生扩展、语音和手机操控需要各自适配与验证。
- 真实模型回复、账号授权回调、快捷键粘贴及其他自定义编辑入口尚未完成验收。

请勿将早期 ArkTS 原型的构建说明用于此 Flutter 工程，也不要把当前调试包视为功能完整版本。
