# 鸿蒙语音通道回归

原 Flutter `dsh/voice` 与 `dsh/voice/events` 协议由 `DshVoicePlugin.ets` 实现：

- 系统识别使用 Core Speech Kit 离线中文引擎；目前只接受 `zh` / `zh-CN`，其他语言明确拒绝。
- 录音使用 Audio Kit，输出与原协议相同的 16 kHz、单声道 PCM16 WAV；缓冲区仅在内存中保存。
- 系统识别在 `onStart` 确认后才开启采集，PCM 按系统 API 要求分成 640 字节帧，结束时仅对最后不足一帧的部分补零。
- 权限由原界面主动请求；能力查询不请求权限或开启麦克风。取消、离开应用、销毁通道均停止采集，迟到回调按会话退役。
- 这不是 SenseVoice 运行时移植；原引擎 SenseVoice 的原生扩展与子进程依赖尚未适配。

SDK 依据：[系统语音识别](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/hms-ai-speechrecognizer)、[音频采集](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-audio-audiocapturer)。实现还核对了本次 API 26 SDK 的实际类型声明。

在仓库根目录运行：

```powershell
node harmony/tests/voice/native.test.cjs D:/工具链/typescript
```

测试直接转译并执行原 ArkTS 类，系统服务由内存替身提供。11 项覆盖能力查询不录音、权限与语言拒绝、WAV 格式、音量范围、初始化取消、系统就绪超时、分句结果、旧回调、时长上限、停止重启竞态和尾帧。它们不等于实际麦克风录音或真机识别准确率验证。

2026-11-01：正常 HAP 已编译、签名并覆盖安装；原聊天框已显示语音按钮，证明设备能力查询可用。真实录音、说话识别、拒绝权限及实际后台退出仍待用户在设备上试用，不能据按钮出现宣称全部通过。

## 2026-11-02 独立离线识别服务真机验收

构建 147 使用独立 UIAbility 向真实 CoreSpeechKit 提交固定合成中文 WAV，未创建 Flutter、账号或 AudioCapturer，没有请求或打开麦克风。严格读取 RIFF/fmt/data 后，等 onStart，按 640 字节/20 ms 输入 232 帧，结束后等待实际 final/last/onComplete。

平板实际结果：完整识别两轮的规范化固定短语均匹配；两轮之间取消输入两帧的会话，未出现尾部 final/complete；同一引擎重开成功，shutdown 与定时器清理全部通过。输入为 Windows 已安装 Huihui 合成的“鸿蒙语音测试，今天开始本机聊天。”，非用户录音。

此结果只覆盖真实离线识别服务及其取消重开。生产插件的采集、权限、事件与原 Flutter 文字回填仍有独立边界，已请求用户做一次实际说话测试；不能以合成输入服务通过替代该结果。测试源码、固定输入与安全报告在本机 work 的 voice-device-probe，尚未纳入正常运行资产。147测试后已覆盖恢复正常146，保留用户数据。
