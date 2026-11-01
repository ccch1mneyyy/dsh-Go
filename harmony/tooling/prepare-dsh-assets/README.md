# 固定 DSH 资产准备

本工具从官方 Android 1.0.2 APK 中提取固定 rc.4 安装树，不执行 npm 生命周期脚本、DSH 或任何二进制，不读取设备或用户 home。

官方发行页：https://github.com/ccch1mneyyy/dsh-Go/releases/tag/v1.0.2

APK：https://github.com/ccch1mneyyy/dsh-Go/releases/download/v1.0.2/dsh-go-1.0.2-arm64.apk

下载后运行（输出必须不存在）：

```powershell
python harmony/tooling/prepare-dsh-assets/prepare.py --apk D:/下载路径/dsh-go-1.0.2-arm64.apk --output D:/Codex/work/dsh-clean-source
python harmony/plugins/dsh_runtime_ohos/package-runtime.py --source D:/Codex/work/dsh-clean-source --output D:/Codex/work/runtime-assets.zip
```

## 来源与边界

- APK SHA-256：`1afb3b363ba47418291ac56c17d661dd25a7520b94901700bfd19ed82859ba17`。
- rootfs SHA-256：`eb5f1318a55b4663faa991ca553c335f1127b8c3f853ba04288f65a9ba18d171`。
- 原 npm v3 锁 SHA-256：`9b61c5b60c82a3b64fb252af5c142d40d0c86aff30a17cdd5e1ca9d73df9a25c`（387998字节）。其 resolved 指向 registry.npmmirror.com。
- 锁与 package.json 是官方 rootfs 的安装产物，不是本工具新解算。直接 `npm ci --ignore-scripts` 会随host平台选不同optional包，且不保证还原官方安装后产物；本工具不把该替代路线称为等价重建。
- 仅提取 `opt/dsh/` 和 `opt/dsh-go/dsh-go-bridge/`。原许可证随原树保留；不提取 `/root`、系统目录或设备用户配置。
- 14576个原普通文件；12个 `.bin` 符号链接不创建，转为校验过目标摘要的 `COMMAND-ENTRIES.json`。映射只是来源记录，不代表平台已经实现这12条命令的执行。
- 原Linux ARM64 native附件保留为惰性原始输入（require-builtin、system、pty、ripgrep、koffi、sharp、sherpa共10个后缀/名称匹配文件）。不是Harmony库，不应加载/执行，也不替代另行从源构建并签名的OHOS库。当前不静默删除文件，以便与原APK逐项比对；如进一步裁剪必须增加可审计排除清单并重新验收。
- `PREPARED-SOURCE.json`逐项记录原文件摘要。生产启动器的平台改写应在验证原输入后执行；本工具不预先混入旧工作目录的诊断或运行时改写。
- `preinit-dsh-home`是旧bootstrap的可选兼容入口，package-runtime未打入；本工具也不复制。新home依赖原CLI的shipped profile初始化。空home最终真机启动仍须验收。
- 本工具保证固定来源导出；尚不由此单独证明“干净输入打包后的本机全功能验收”。必须比较旧生产输入差异并实际启动测试后才能给出该结论。

## 本轮重放结果（2026-11-01）

已从固定APK导出到全新目录并完成逐文件SHA-256核对：14576项全部与原始stage相等；同14576项也全部与原生产输入相等。生产输入额外有6项Windows宿主测试用 `node-addon-require-builtin-win32-x64-msvc` 包文件（包括1个.node），清洁导出不包含该非原APK包。原APK中的Linux原生文件仍保持原样。12个命令目标均为经过摘要验证的普通文件，未创建符号链接。

首次试跑曾因检查不在导出范围内的系统条目名称而拒绝；已修为先限定两个opt前缀，再严格验证所有选中条目，使用第二个全新目录重放成功。失败输出不会被当作成功结果，也不覆盖已有目录。

已用当前生产packager打包清洁source：14587文件，归档SHA-256 `431e92e59844adc3cbfe9e003762afd949d2c7c79848671ff885a478ba86cc31`。包内核验scriptver-120、repeat启用、manifest helper、原npm锁摘要均正确，无Windows测试addon和preinit模板。四类路径拒绝回归通过。来源导出与打包复现已补齐；清洁包实际平板启动仍由最终120验收确认。
