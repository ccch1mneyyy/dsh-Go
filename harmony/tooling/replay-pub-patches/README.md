# 5个固定Pub包的离线补丁重放

此目录只保存固定版本、原始/补丁后源码树SHA256、最小补丁、对应许可证和重放脚本，不vendor整份第三方包。生成的包放在开发者指定的仓库外work目录；不会改原始Pub缓存、主应用overrides、SDK、签名或设备。

## 来源与修改范围

| 包 | 固定版本 | 修改文件数 | 实际修改 |
| --- | --- | --- | --- |
| [material_ui](https://pub.dev/packages/material_ui/versions/1.8.0) | 1.8.0 | 37 | 完整处理OHOS枚举，沿用相应Android移动语义 |
| [cupertino_ui](https://pub.dev/packages/cupertino_ui/versions/1.1.4) | 1.1.4 | 11 | 处理OHOS枚举，保持现有移动交互路径 |
| [xterm](https://pub.dev/packages/xterm/versions/4.0.0) | 4.0.0 | 1 | OHOS终端快捷键走已有移动/通用分支 |
| [gpt_markdown](https://pub.dev/packages/gpt_markdown/versions/1.4.0) | 1.4.0 | 1 | OHOS使用已有移动滚动布局分支 |
| [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage/versions/11.2.0) | 11.2.0 | 1 | OHOS使用应用HUKS桥接的默认选项，不传Android专用选项 |

精确包归档SHA256来自原仓库提交 `98921aae113642c36b591dda224989a095ebd347` 的 `app/pubspec.lock`，与本机Pub缓存hosted-hashes记录逐一相同。**此次没有联网重新下载或计算远端归档本体的hash**；不能把缓存元数据比对说成已重新验证远端归档。重放另对本地原始包全部2220个源码/资源文件生成固定树指纹，并验证生成结果与已成功运行的副本逐字节相符。

所有固定值、51个改动文件的前后SHA256和树指纹算法见 `packages.json`。脚本要求原始缓存树与该清单精确一致，未知源码或版本直接停止，不猜替代版本、不更新依赖。Pub包是hosted发行物，没有为它们编造Git提交SHA；这里分别记录归档SHA256和源码树SHA256。

原许可证位于 `licenses/`，未改写版权。xterm为MIT，其他4包保留各自BSD许可原文；生成包仍包含原包全部许可、作者记录及源码头。补丁文件与许可证使用 `.gitattributes` 保留原始字节，避免Git检出换行改变hash。

## 离线生成

需要Node.js和Git，以及已经由正常Pub流程取得的精确版本缓存。当前脚本不联网、不调用Pub、Flutter或Hvigor，不下载或执行其他二进制。将示例路径替换为实际的D盘缓存与一个新的空work目录：

```powershell
node .\harmony\tooling\replay-pub-patches\replay.cjs `
  --pub-cache 'D:\开发缓存\pub-cache' `
  --output 'D:\开发工作\harmony\replayed-pub-packages'
```

流程：先核对5包归档元数据、完整原始树、补丁及许可；再复制到独立输出目录，执行git apply预检查/应用及明确的换行后处理，最后核对完整补丁后树。缓存和仓库内路径均禁止作为输出；输出目录已有内容时也停止，不删除或覆盖旧结果。校验失败后保留隔离输出供检查，不修改来源。

输出内容：5个生成包、只含这5项的 `pubspec_overrides.yaml` 候选、`replay-result.json` 及本机 `.gitignore`。输出位于仓库外且带忽略规则，不进入提交。**不要直接用候选覆盖主app现有overrides**：仍有其他4个平台后端需要主线程统一整合。确认全部依赖来源后再由主线程合并并正常解析，当前脚本不做这一步。

完整树指纹排除 `.dart_tool/.git/build/oh_modules/.hvigor/node_modules`，以及Flutter/Hvigor生成状态文件。它核对包的全部原始源码、资源和许可，不把构建缓存当源码。复制过程中遇符号链接即停止，避免意外带入本机目录。

## 换行与验证边界

当前已成功的material_ui副本中 `lib/src/text_field.dart` 为CRLF，而原Pub缓存为LF。实际只加6行OHOS分支，直接diff会产生整文件噪音。此处保存最小LF补丁，并在清单中明确仅对该文件进行CRLF后处理，最终仍与成功副本字节完全一致。没有借迁移修改成功包或SDK。

2026-10-30已在D盘独立work实际运行脚本：5包全部通过原始树校验、补丁预检查/应用和补丁后树校验，累计2220个文件与已成功副本一致。此为可重复生成验证，不等于迁移后已重新编译或完成全部功能验收。material_ui/cupertino_ui原包dev依赖还有上游monorepo的flutter_goldens路径，主app解析不会使用依赖包的dev依赖；不能据主app构建声称各包独立测试环境也已补齐。

这些包补OHOS枚举，面向本项目固定的Flutter-OH 3.47.7预览。普通Flutter没有TargetPlatform.ohos，不应把它们直接当作可用于所有普通Flutter版本的跨平台发行包。flutter_secure_storage补丁还要求本应用提供真实HUKS桥接，本补丁本身不冒充存储后端。
