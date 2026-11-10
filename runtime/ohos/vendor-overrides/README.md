# OHOS vendor 覆盖：DSH npm 包的最终字节

`runtime/patches/*.diff` 由 `patch-dsh` 从**未改动的 npm 前缀**按链应用，链上每个 diff 都带 before/after 摘要。
下面这四个文件当前的改动是在**链尾状态**上继续做的（附件落盘、发布、会话投递这些路径此前已有多轮覆盖），
还没有用 pristine 前缀重算 pins，因此暂不并入 `patch-dsh` 链，先以完整文件的形式保存在这里。

`node_modules/` 本身不进 git（见 `.gitignore`），所以不存这份拷贝的话，这些改动只存在于打好的 HAP 里，
下次重新拉前缀就会整体退回旧行为。

## 清单

| 文件 | 改动意图 |
| --- | --- |
| `@deepseek-ai/dsh-experimental-inspector/lib/worker.js` | `node:inspector` 改惰性导入。OHOS 自带的 Node 没有 inspector 子系统，静态导入会让整个 bundle 在模块图阶段就抛 `ERR_INSPECTOR_NOT_AVAILABLE`，插件条目永远是 failed，设置页显示「插件没有启动」。现在插件能正常激活，只有真的挂 DevTools 时才报错。 |
| `@deepseek-ai/dsh-attachment-local/lib/index.js` | 纯 JS 解析图片头（OHOS 上没有 sharp），`syncDirectory` 在系统目录返回 `EACCES` 时降级为只记日志，排他发布遇 `EEXIST` 不再回退到会 `EACCES` 的 `copyFile`(交给外层 sha256 幂等分支)。 |
| `@deepseek-ai/dsh-client-file-upload/lib/index.js` | 上传回执（receipt）跨实例登记到 `globalThis.__ohosReceipts`，WebView 侧实例重建后仍能对上已落盘的对象。 |
| `@deepseek-ai/dsh-api-session-controller/lib/index.js` | prompt 投递时对 receipt 做跨 session 兜底，避免回执登记在内核实例、投递走另一个实例时被判为无附件。 |

## 套用

打包 `runtime.zip` 之前，把这里的 `node_modules/` 覆盖到运行时树的同名路径：

```sh
runtime/ohos/vendor-overrides/apply.sh /absolute/path/to/runtime/tree
```

脚本按 `SHA256SUMS` 校验目标文件，缺一个就非零退出——宁可构建失败，也不要静默出一份退回旧行为的包。

## 待收敛

有了 pristine 前缀之后，应当：

1. 按 `--target ohos` 跑完现有 136 条链，得到链尾树；
2. 把这里的四个文件与链尾做 diff，作为**新的链尾补丁**加入 `runtime/patches/`；
3. 同步把名字写进 `pins.json` 的 `targetSets.ohos`，并用 `--record` 重算 after 摘要；
4. 删掉本目录。

`TARGETS.md` 的集合校验要求「目录内全部 `.diff` 与两个集合的并集一致」，所以第 3 步不能漏，
否则 `build-runtime.sh` 会在写入前直接失败。
