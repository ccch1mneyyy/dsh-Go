# 安全粘贴默认菜单的固定SDK补丁

此目录配合 `harmony/plugins/harmony_secure_paste`，为原版Flutter输入框的OHOS默认菜单增加安全粘贴入口。它不会移植或改写业务页面。只有用户点击原生面板中真实可见的系统PasteButton后，插件才请求读取；回填继续检查输入框和原选区。其他平台仍使用原默认菜单。

这是DSH配套的本地工具链补丁，不能直接当作适用于所有Flutter应用的上游框架实现。未带插件的OHOS应用不应应用该补丁。自定义菜单、快捷键和业务直接读取剪贴板不在此补丁覆盖范围。

## 固定来源

- [CPF-Flutter官方仓库](https://gitcode.com/CPF-Flutter/flutter_flutter/tree/oh-3.47.7-preview)
- 提交：`650641656fef1d0578f0bc1ed8f7a35087fc99f3`
- Flutter：`3.47.7+ohos-0.0.1-pre`；Dart：`3.13.5`
- 此次真机环境：HarmonyOS SDK `26.0.0`、Windows CLT `26.0.0.851`

精确源码路径和SHA256位于 `pinned-source.json`。Flutter原框架许可保留在 `FLUTTER_LICENSE`；本仓库新增实现的许可遵从仓库根LICENSE。这里只含文本源码、补丁、校验脚本和说明，没有SDK二进制、引擎HAR、签名、设备资料或联调日志。

## 应用与验证

使用独立的固定提交工具副本，先停掉共享该SDK的Flutter构建或测试。SDK和备份目录都由调用者显式指定，以下例子中的D盘目录应替换为自己的实际位置；脚本不自动下载或升级工具链。

```powershell
& .\harmony\tooling\secure-paste-sdk-patch\apply.ps1 `
  -SdkRoot 'D:\开发工具\flutter-ohos' `
  -BackupRoot 'D:\开发缓存\sdk原文件备份'
```

脚本先检查Git提交、补丁、源文件hash与 `git apply --check`，任何未知改动都会停止；再将原文件备份到唯一目录。已知早期PlatformView版helper可升级为独立Future版，其他未知helper不会覆盖。完整补丁已存在时仅校验，不重复修改。脚本不触发pub get、构建或设备操作。

只读检查已应用状态：

```powershell
& .\harmony\tooling\secure-paste-sdk-patch\verify.ps1 `
  -SdkRoot 'D:\开发工具\flutter-ohos'
```

保留源码原始字节进行SHA256校验；脚本识别已知CRLF检出和官方Git对象LF两种精确hash，自动选相应补丁，不将未知文本视为兼容。`.gitattributes`将两份补丁和helper设为保留字节，避免克隆时改写校验对象。补丁最后一行保留helper源文件的CR字节，Git可能提示一行whitespace warning，不应因此自动格式化或声称版本失配。校验失败时停止并检查固定来源，不删除缓存或关闭验证。

应用后，在 `app/` 中使用此SDK正常解析仓库的相对路径依赖再构建。调试签名由开发者本机配置，证书、私钥和设备授权资料不进入仓库。当前主线程已验证插件相对路径离线解析成功；迁移后完整构建结果应另行记录，不能用文件校验代替构建和真机验收。

## 已有证据与范围

迁移前同字节实现已通过真实MatePad上的系统按钮授权、原生面板关闭及原版TextInput回填；固定Flutter测试9项、Native Session夹具7项、插件调用路径夹具3项通过。夹具只使用固定替身，不能替代系统真实授权。

此前失败由真实日志定位为临时工具栏PlatformView先被销毁；当前请求改为插件级MethodChannel Future与独立Session，不依赖菜单寿命。面板使用现窗口UIContext的ComponentContent/openCustomDialog，不采用透明覆盖、模拟授权或放宽disposed保护。

早期还试过临时引擎HAR的clipboardHasStrings补丁；该补丁不在交付范围。主线程恢复原始HAR字节后，重新构建20.4秒并签名安装成功，真机长按菜单、原生面板、用户亲点系统按钮和测试文本回填全部通过。最终不依赖clipboardHasStrings临时补丁。

交付脚本已在work下两个隔离的固定提交源码夹具中实际运行：LF、CRLF首次应用与第二次幂等校验均通过；另验证已知旧helper升级成功、未知修改被拒绝且原字节未变。这些夹具只检出必要文本文件，没有运行Flutter或写入实际SDK。
