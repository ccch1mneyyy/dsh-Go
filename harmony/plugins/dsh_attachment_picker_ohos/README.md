# DSH 鸿蒙附件平台实现

此本地插件保留原版 `FilePicker` / `ImagePicker` 的调用页面，通过各自的现代 platform_interface 注册实现。代码遵循仓库根目录 AGPL-3.0 许可证，LICENSE 为根许可证原样副本。

原应用依赖保持 `file_picker ^13.1.0`、`image_picker ^1.2.4`。主线程在 `app/pubspec.yaml` 新增直接依赖即可；本插件不替换这两个 app-facing 包，不降级版本：

```yaml
dependencies:
  dsh_attachment_picker_ohos:
    path: ../harmony/plugins/dsh_attachment_picker_ohos
```

OHOS 原生与 Dart 插件注册均由工具根据 pubspec 生成；不要手改 GeneratedPluginRegistrant。也不要在非 OHOS 平台主动调用 registerWith。插件需要前台 UIAbility；平台错误保留固定错误标识与原生数字码，不记录 URI、名称和内容。

当前覆盖原版实际使用的附件行为：

- 相册：多选图片，传递数量、最大宽高与质量；论坛相册为单图。
- 拍照：通过系统 CameraPicker，显式使用自有沙箱 saveUri，避免默认保存到公共图库。取消返回空结果。
- 文件：系统 DocumentViewPicker；单选用于小文本/SSH 私钥，多选用于附件。选择时只取名称与可用大小，后续按 64KB 分段读取系统选取的句柄，不预复制完整文件。每次读取结束都关闭描述符；取消流后不请求后续块，原业务大小预算和前缀嗅探继续生效。未选取句柄、负偏移、过大块均拒绝。
- 图片：按 EXIF 方向修正并保持宽高比，不放大；PNG 保持 PNG，其他静态格式输出 JPEG。从像素重新打包且不复制 EXIF。处理失败明确报错，不回退为未缩放原图。

明确限制：只实现原应用当前使用的图片入口和文件选取接口。视频、混合媒体、图片丢失结果恢复、保存文件、选目录不在当前实现中；不把它们标为已支持。文件类型当前支持 any 和 custom 扩展名；自定义标题、初始目录、文件压缩明确抛不支持。图片 `requestFullMetadata: true` 明确拒绝；原版三处图片调用均为 false。动图会静态化，未提供动画帧保留保证。文件 URI 授权失效时明确报错，未实现跨重启持久授权。相机非零结果码与设备取消行为需真机核对，不能把真实错误吞作取消。

测试：`dart analyze lib test` 无问题；独立 `flutter test --no-pub` 8 项通过、0 跳过（Windows 宿主通道模拟）。`work/harmony/attachment-picker-model-test.cjs` 另有 7 项 Node 原生边界模拟通过，均为内存夹具。它们不等于 OHOS 原生编译或真机选择器通过。完整核对和来源见 `D:\Codex\2026-10-28\zhe\work\harmony\attachment-picker-integration.md`。
