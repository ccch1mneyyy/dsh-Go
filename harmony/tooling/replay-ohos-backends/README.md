# 固定 Git OHOS 后端离线重放

此目录仅保存四包的固定来源、源码树指纹、最小功能补丁、原许可证与导出脚本，不 vendor 完整插件或 SDK。产物生成在仓库外 D 盘 work；不修改原始克隆、成功副本、主 app overrides、Pub 缓存或设备，也不运行 pub get / Flutter / Hvigor。

## 固定来源

四包均来自 `https://gitcode.com/CPF-Flutter/flutter_packages.git`。精确 SHA 与包路径记录在 `packages.json`，对应主 app 当前直接 Git 依赖：

| 包 | 包自身版本 | 固定提交 | Git 内包路径 | 功能补丁 |
| --- | --- | --- | --- | --- |
| shared_preferences_ohos | 2.5.4 | 143d83e7669a359a1ab1ee6558c4a2e4f7f4c53f | packages/shared_preferences/shared_preferences_ohos | 无 |
| path_provider_ohos | 2.2.17 | d4e49daa0acbd0bc419d58b1da27d64d44fab54b | packages/path_provider/path_provider_ohos | 无 |
| url_launcher_ohos | 6.3.2 | ae4494a78db5a9e0fe760b0eba9231605ae45716 | packages/url_launcher/url_launcher_ohos | 3 文件：外部 openLink、等待异步结果、明确拒绝不支持模式与非法地址 |
| webview_flutter_ohos | 4.7.0 | 3467191089ef4abc76132fff65b8e3354c2c21dd | packages/webview_flutter/webview_flutter_ohos | 1 文件 1 行：仅主框架受导航拦截 |

克隆目录名称并非包版本依据：`path-provider-2.1.5-ohos` 实际目标包版本为 **2.2.17**，WebView 分支名含 4.13.1 而后端包为 **4.7.0**。上述版本均直接读取固定提交 pubspec.yaml。

脚本要求对应提交对象已存在于 `--sources` 指定目录的四个官方克隆中，不联网补对象、不改分支、不读工作树来冒充原始 Git 字节。先核对 origin URL，再以 `git --no-replace-objects rev-parse` 核对固定 commit，使用 ls-tree/cat-file 读取该提交的包 blob。检查的是本地已有对象及记录的远程地址，本轮没有联网重新验证远程服务状态或声称提交已做签名验证。

许可证从固定提交的原始 LICENSE blob 逐字节导出至 `licenses/`，SHA256 保存在清单；完整原包和各源文件版权头也随生成包保留，不重写为本项目所有。补丁原有版权上下文保留。`.gitattributes` 禁止 Git 改写补丁和许可字节。

## 使用

需要 Windows 上的 Node.js、Git，以及已取得上述四个固定提交的克隆。当前默认目录命名见清单；源码父目录可更换。

```powershell
node .\harmony\tooling\replay-ohos-backends\replay.cjs `
  --sources 'D:\Codex\tools\harmony\plugin-sources' `
  --output 'D:\开发工作\harmony\replayed-ohos-backends'
```

输出必须是仓库和来源之外的 D 盘新目录（或已有空目录），已有内容时直接停止，不清理覆盖。源树/补丁/许可/最终指纹任一不匹配即停止，失败的隔离产物保留用于检查。

输出包含四个包、仅四项的 `pubspec_overrides.yaml` 候选、`replay-result.json` 与本地 `.gitignore`。**不要用候选覆盖主应用现有 overrides**；另有5个 Pub 补丁包，由主线程统一合并。四个 OHOS 后端必须继续在 dependencies 被引用，单独 override 不会把新插件引入应用。

## 最小补丁与换行

固定 Git blob 是 LF，当前已成功副本大部分经 Windows Git 检出为 CRLF。直接二进制 diff 会产生无意义整文件改动。

这里将原功能补丁统一为 LF，先在原始 Git blob 字节上 apply --check / apply，再按 `lineEndingsAfterPatch` 明确清单恢复成功副本的 CRLF；前两包没有任何功能补丁，仅有同样的检出换行重放。最终产物仍与成功副本逐字节一致。清单的 `modifiedFiles` 只列4个实质修改文件，分别给原始、LF补丁后、最终字节 SHA256，换行不会混称功能改动。

有效源码树包含原包的源码、资源、示例、测试、许可。排除 `.git/.dart_tool/build/oh_modules/.hvigor/node_modules` 目录，以及 `.flutter-plugins-dependencies/.packages/BuildProfile.ets/oh-package-lock.json5` 工具生成文件；不会把旧构建状态复制成可复现依赖。遇有效树符号链接或非普通 Git blob 时停止。

指纹算法：相对路径按字符排序，每文件构成 `path + NUL + 文件SHA256 + LF`，全部拼接后 SHA256。原 Git 对象树和最终有效树的数量/指纹均固定于 `packages.json`。

## 本次验证与范围

2026-10-30 在仓库外的独立工作目录完成实际离线重放：

- shared_preferences_ohos：70 文件；path_provider_ohos：56 文件；url_launcher_ohos：60 文件；webview_flutter_ohos：129 文件；累计315文件。
- 四包原始 Git 树、许可、补丁（后两包）及最终树指纹全部通过。
- 另直接逐个 Buffer 比较315个文件，均与当前成功包有效源码字节一致，文件集合相同。结果在该输出目录 `byte-comparison.json`。
- 重用非空输出目录、输出到主仓库，两种预期拒绝均通过，未生成禁止的目录。
- 四个原克隆前后 git status 均干净，成功副本未写入，主应用配置未改。

这是离线生成和字节一致性验证，不是重新完成原生构建、功能回归或设备验收。现有本地功能验证边界详见工作文档 `url-launcher-integration.md` 与 `webview-integration.md`；该目录不复制临时测试环境、完整包或 SDK。
