# iOS 支持：范围、现状与实施顺序

[roadmap.md](roadmap.md) 已经定了方向：**「iOS：只做远程客户端（iOS 不允许本地运行 Linux 环境）」**。
本文把这个方向落成可执行的边界：哪些现状挡路、每个平台通道在 iOS 上的去向、按什么顺序推进、哪些事只有 macOS 能做。

## 1. 为什么 iOS 不能有本机引擎

| 依赖 | iOS 上的实际情况 |
|---|---|
| PRoot | 依赖 `ptrace`/`seccomp` 与 Linux 用户态，iOS 没有可用的等价物；App 不能 `fork`/`exec` 任意二进制 |
| 内置 Ubuntu rootfs + Node | App Store 审核指南 2.5.2 不允许下载或执行引入新功能的代码；自签/侧载可以绕过上架，但仍然没有 `execv` 这条路 |
| 前台服务 / 常驻进程 | iOS 没有 Android 那种前台服务；只能靠有限的后台执行时间 |

结论：iOS 版**不打包 rootfs，不起 `dsh web`**。它连接远程主机（SSH / DSH Remote）或局域网里的 DSH，
能力等价于 Android 版「只连接远程主机」的那条路径（README「只连电脑或服务器上的 DSH 可以不装运行环境」）。

## 2. 现状测量（都可以在仓库里复现）

| 项 | 结果 |
|---|---|
| 平台目录 | 只有 `app/android`，没有 `app/ios` |
| 自定义平台通道 | **31 个** 唯一名字（`MethodChannel` / `EventChannel` 的字面量） |
| 通道调用处的兜底 | 26 个通道所在文件出现 `MissingPluginException` / `PlatformException` 处理，**5 个没有**：`dsh/app`、`dsh/files`、`dsh/share`、`dsh/update`、`dsh/web-files` |
| 平台判断 | 全仓库只有 **1 处** `Platform.isAndroid` / `Platform.isIOS` |
| 本机引擎的 Dart 侧 | `app/lib/runtime` 4 个文件、1149 行，被 **59 个文件** import |
| 跨平台依赖 | `dartssh2`、`flutter_webrtc`、`webview_flutter`、`xterm`、`dsh_client`、`dsh_remote` 都有 iOS 路径 |

复现（数字都是在仓库上跑出来的）：

```bash
ls app                                       # app/android 有，app/ios 没有
# 通道字面量；别用 grep "dsh/..."，那会把 dsh/node_modules/、dsh/skills/ 这类路径也算进来（39 个）
grep -rhoE "(Method|Event)Channel\('[^']+'" app/lib --include='*.dart' \
  | cut -d"'" -f2 | sort -u | wc -l                    # 31
grep -rn "Platform.isAndroid\|Platform.isIOS" app/lib --include="*.dart" | wc -l   # 1
find app/lib/runtime -name "*.dart" | wc -l            # 4
grep -rl "runtime/" app/lib --include="*.dart" | wc -l # 59
```

**最后一行是这活能做成的前提**：远程连接、WebRTC 直连、终端渲染、Markdown 与 `dsh-ui` 卡片都是纯 Dart 或跨平台插件，
不依赖 Android。真正卡住的是那 31 个通道和 `lib/runtime` 这层。

## 3. 渠道在 iOS 上的去向

判定口径只有三种：**保留**（iOS 实现等价语义）、**降级**（保留入口，功能说明式失效）、**移除**（iOS 上不出现入口）。

| 通道 | iOS | 说明 |
|---|---|---|
| `dsh/runtime`、`dsh/runtime/events` | 移除 | 本机引擎不存在；要保证没有引擎时 UI 直接进入「远程」而不是卡在启动页 |
| `dsh/phone`、`dsh/phone/events` | 移除 | 手机操控依赖无障碍/ADB，iOS 无对应能力 |
| `dsh/pet_overlay`、`dsh/picture_shortcut`、`dsh/islands`、`dsh/launcher_icon`、`dsh/dynamic_color` | 移除 | Android 专属外观能力 |
| `dsh/notify`、`dsh/notify/taps`、`dsh/notify/actions` | 保留 | iOS 用 UNUserNotificationCenter；`actions` 对应可操作通知 |
| `dsh/links`、`dsh/shortcuts`、`dsh/share` | 保留 | 分享扩展 / 通用链接 / Siri 快捷指令，语义一致 |
| `dsh/media`、`dsh/native-media`、`dsh/native-files`、`dsh/files`、`dsh/web-files` | 保留 | 走 PHPicker / UIDocumentPicker；沙箱路径语义要重写 |
| `dsh/voice`、`dsh/voice/events` | 降级 | iOS 用 Speech 框架可做流式识别，但后台录音与 Android 的常驻行为不同 |
| `dsh/diagnostics`、`dsh/performance`、`dsh/usage` | 降级 | 保留读数，去掉 Android 专有字段（如 proot/前台服务） |
| `dsh/update` | 移除 | 不经过 App Store 的更新链路在 iOS 上不可用；改由 TestFlight/商店更新 |
| `dsh/launch`、`dsh/launch_clip`、`dsh/app` | 保留/改造 | 与「App 内启动本机引擎」绑定的部分要拆开 |

## 4. 实施顺序

**P0 —— 不需要 macOS，在 Android 上也能验**
1. 把「本机引擎是否存在」变成一个显式能力（例如 `Capabilities.localEngine`），UI 依据它决定是否显示引擎相关入口；
   Android 上行为不变，这本身就是可回归的改动。
2. 给第 2 节里那 5 个**没有兜底**的通道补 `MissingPluginException` 处理 —— 它们在 iOS 上会直接抛异常。
3. 新增一个平台能力表（本文第 3 节），让「某个功能在 iOS 上是什么状态」有单一出处。

**P1 —— 需要 macOS + Xcode**
4. `flutter create --platforms=ios` 生成 `app/ios`，先只跑通：远程主机列表 → 连接 → 会话 → 发消息 → 终端。
5. 按第 3 节实现「保留」的通道；「降级」的先留空实现 + 文案。

**P2 —— 分发**
6. TestFlight（需要 Apple Developer 账号）或自签名（需要设备 UDID / AltStore 类工具）。

## 5. 需要维护者决定的三件事

1. **分发方式**：TestFlight 需要年费账号；自签有 7 天/90 天限制。这决定 P2 能不能做。
2. **AGPL-3.0 与 App Store 的关系**：AGPL 与 App Store 的单次分发与 DRM 条款存在公认冲突，仓库当前是 AGPL-3.0；
   iOS 版走 TestFlight 或自签也需要一个明确说法。
3. **iOS 上「手机操控」是否需要的等价物**：iOS 没有无障碍注入；如果要，只能走「由主机上的 DSH 执行」这条路。

## 6. 本文没有验证的部分

本文对 iOS 行为的描述**全部来自静态推断**（读代码 + 平台常识），没有在 macOS / Xcode / 真机上验证过：
本机没有 `flutter`、`dart`、`xcodebuild`。第 2 节的数字是在仓库上实跑出来的，可以复现。
