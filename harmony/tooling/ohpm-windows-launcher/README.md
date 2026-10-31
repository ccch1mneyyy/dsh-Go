# Windows OHPM 启动器修复

仅适用于本项目已验证的 CLT `26.0.0.851` 解压副本。在当前 Windows 环境，
Hvigor 调用原 `ohpm.bat` 时出现 `BATCH RECURSION exceeds STACK limits`；
同包 Node 直接调用原 `pm-cli.js` 正常。本修复只简化启动器，仍使用官方 CLI，
保留参数和退出码，不跳过依赖校验。

仅在复现该问题后应用。脚本要求显式提供 CLT 和备份目录，校验已知原始字节，
遇到未知版本或修改即停止；已应用时只校验，不重复写入。

```powershell
./apply.ps1 -CltRoot 'D:/开发工具/command-line-tools' -BackupRoot 'D:/开发项目/work/tool-backups'
```

路径只是示例。`CltRoot` 下应包含 `ohpm/bin/ohpm.bat` 与 `tool/node/node.exe`。
恢复时将脚本输出的 `ohpm.original.bat` 复制回原启动器路径即可；无需删除缓存。

原入口的 SHA256 为 `07C834FC20406E85757142118B87AAFF8DFA59EB52D103E6CAB69C71BAF285F1`，
修复入口为 `654EB7B99EEC3D7B489EE86F06F819791024169CAF3EADC6153F6D1B02729393`。
`ohpm.bat` 保留发行文件的版权声明和精确换行；不包含工具二进制。

已验证 Hvigor 的调用形式、空格/中文/感叹号参数和非零退出码传递，
并已用该修复完成本项目 HAP 构建。此结论限于上述版本和实测环境。
