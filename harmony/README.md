# DSH Go 鸿蒙适配

最终应用复用原版 `app/lib` Flutter 页面与 `packages/dsh_client` 协议，鸿蒙宿主位于 [`app/ohos`](../app/ohos/README.md)。本目录的 `plugins/`、`tooling/` 和 `tests/` 为该宿主提供系统能力、本机引擎及验证材料。根目录保留的早期 ArkTS 原型不是最终应用入口，不应作为正式工程构建。

## 当前范围

MatePad 已验证原页面、本机引擎生命周期、HUKS、安全粘贴、附件与相机回传、内嵌网页及与安卓版同源的四种图标。本机模式已通过无 JIT WebAssembly、原 fetch、独立 UID 的一次性 PTC、真实文件工具和权限检查。无 Key 回环 fixture 对话经过原 agent loop 与持久化，并在真实进程重启后读回。用户授权后，127 正常包还通过已存 API Key 完成一次真实 DeepSeek 短回复，原 RPC/mux 流式事件、历史、冷读及 Flutter 页面显示均通过，诊断未读取或输出 Key。清洁正常包 121 通过认证、列表、标题持久化和文本附件上传；123 在原引擎页停止并确认旧进程退出后，可见地启动新进程并通过认证、列表与标题检查。123 与 127 整个应用 force-stop 后冷启动的认证、列表及事件通道已通过。原账号浏览器登录也已提交成功，资料、余额与账号模型目录可用；130 无诊断正常包完全停止再冷启动后仍保持登录。账号模型生成尚未实测，浏览器前台期间本机接口曾超时，不承诺后台常驻。详细证据范围和未覆盖项见 [宿主说明](../app/ohos/README.md) 与 [本机验收摘要](docs/local-mode-validation.md)。

隔离任务的实际系统工作目录为 `/`，宿主工作区通过原工具绑定按策略访问；不承诺任意 shell、外部命令、缓存原生扩展或持久 PTC。已验证子集不能代表与安卓版全部功能一致。 安全模式、自动安全模式、启动方式切换、LKG恢复、重置及其保留选项、后台/电池开关尚未实现，相关变更方法明确返回 `UNSUPPORTED`，不会伪报清理成功或删除用户数据；LKG只读查询返回不可用。

## 构建入口

1. 按 [宿主工具链](../app/ohos/README.md#工具链与源码入口) 固定 Flutter-OH 与 API 26，重放 [Pub 补丁](tooling/replay-pub-patches)、[鸿蒙后端](tooling/replay-ohos-backends) 和 [安全粘贴框架补丁](tooling/secure-paste-sdk-patch)。
2. 准备 [同源 Node/DrumBrake 运行库](tooling/node-runtime/drumbrake-compressed/README.md)，按 [原生桥构建说明](tooling/NATIVE-RUNTIME-BUILD.md) 生成匹配的桥接库。已有桥接重放证据不能代替尚未重新执行的干净 Node 长编译。
3. 先用[清洁资产导出工具](tooling/prepare-dsh-assets/README.md)校验官方 APK 并导出固定 rc.4 树（14576 个原文件与 12 个命令映射已实际重放），再通过 [运行资产打包脚本](plugins/dsh_runtime_ohos/package-runtime.py) 装配固定 DSH 与平台实现，使用 `app/ohos` 构建并在本机配置签名。不要提交凭据、设备标识、本机路径锁文件或生成包。
4. 运行 [生命周期及隔离测试](tests/runtime-lifecycle)，再做正常宿主真机验收。[固定设备验收夹具](tests/runtime-lifecycle/device-fixtures/README.md) 只用于独立测试包，不进入正常运行资产；测试后覆盖恢复正常应用，不卸载用户数据。

## 许可与来源

项目代码遵守根目录 [AGPL-3.0 许可](../LICENSE)。图标等品牌素材继续遵守 [ASSETS.md](../ASSETS.md)，不因平台适配改变授权。

Node、V8、libuv 的许可保留在 [Node 重放目录](tooling/node-runtime/drumbrake-compressed)；Pub 与鸿蒙后端各自许可保留在 [Pub licenses](tooling/replay-pub-patches/licenses) 和 [OHOS licenses](tooling/replay-ohos-backends/licenses)。Flutter 框架补丁保留 [原许可](tooling/secure-paste-sdk-patch/FLUTTER_LICENSE)，附件与安全粘贴插件也保留各自 LICENSE。打包或分发时须一并保留相应第三方声明。
