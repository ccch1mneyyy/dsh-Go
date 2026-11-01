# 鸿蒙会话排他发布

原持久化包的两处硬链接同时承担“原子发布”和“目标已存在就拒绝”的语义。普通 rename 会覆盖目标，不能用于会话创建或代际迁移。鸿蒙分支通过签名 Node-API 库调用官方 libc 的 renameat2(RENAME_NOREPLACE)，不回退覆盖操作，不用存在性预检查代替排他发布。

## 构建和打包

`harmony/tooling/build-publish-addon.ps1` 的参数：NativeSdk 为官方native SDK根；NodeSource为所用Node源码根；NodeLibrary为同次运行时构建的libnode.so；OutputDirectory为D盘工作产物目录。脚本从仓库publish.c构建，不修改第三方源码；Node公共头/libuv公共头的原许可随其源码保留。

输出libdsh_publish.so、elf-report.txt、build-result.json。清单包含版本、源文件/JS模块/运行库/产物SHA256；deviceTested默认false。必须确认AArch64、SONAME正确、DT_NEEDED含libnode.so且不含ArkTS的libace_napi。

- HAP原生库目录纳入libdsh_publish.so，与libnode.so同属于签名产物。
- 运行时ZIP纳入`transport/persistence-publish.mjs`和新版bootstrap，前者从仓库assets同名文件复制。
- 更新运行时资产版本和归档/文件摘要，使旧缓存得到新模块。不要只替换一个SO而沿用旧资产摘要。
- 补丁能迁移此前带HARMONY_LINK_FALLBACK的两处错误rename；未知源码锚点会明确失败，避免静默启动不安全实现。

## 语义

publishNoReplaceSync成功消费源文件，失败抛Node式code、负errno和syscall，不在错误中加入文件路径。EEXIST保留源和目标，其它错误不能当作冲突吞掉。

第一处代际迁移成功后先把stage路径标记已消费，再同步目标目录，之后保持原校验流程。这样目录同步失败保留原异常，不会再清理已不存在stage。冲突时仍验证原目标并清理未消费stage。第二处新会话创建保留原EEXIST异常、目录同步和force清理tmp流程。其它平台继续原link行为。

## 验证边界

独立NativeChildProcess探针已验证同目录新目标、EEXIST保留内容与源、两线程仅一方成功及目录同步。该结果仅证明设备文件系统原语，**不代表新Node-API库加载或DSH会话验收已完成**。

本机测试以环境变量DSH_PERSISTENCE_SOURCE指定固定资产中dsh-session-persistence-jsonl/lib/index.js，运行`node --test harmony/tests/runtime-lifecycle/persistence-publish.test.mjs`。测试提取实际源函数，覆盖补丁迁移/幂等/锚点失配、排他冲突、源消费与同步顺序、同步失败、冲突验证及清理、其它POSIX平台和新会话失败清理。原生调用在此使用可控替身，不能据此宣称原生加载已通过。

父任务还需统一构建签名HAP后真实验证Node-API加载、会话创建、冲突不覆盖、持久化及停止重启重放。没有通过这些步骤前不提交完成声明。
