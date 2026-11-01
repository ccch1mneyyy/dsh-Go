# 鸿蒙隔离绑定 PTC 入口生成

`node patch-ptc-runtime.mjs <原包lib/index.js> <新包lib/ohos-index.js>` 校验固定 rc4 源 SHA256 与唯一锚点，输出独立入口。输出应放原 PTC 包 lib 同目录，以保持相对 process.js 定位；不可覆盖原 index.js。完整保留第三方包 LICENSE。更新原版本时必须人工审查并重新固定摘要，不能绕过摘要检查。

导出 OhosIsolatedPtcRuntime 与 default。配置必须 executionMode=per-call、launch.kind=node-script；需要正式 subprocess factory 的只读 ohosIsolatedPtc 标记。标记只用于装配，实际隔离由原生子进程实现，不是安全认证。

resolve 保留请求 cwd/policy/bindings，新增 workerCwd='/'、executionScope='isolated-bindings'；run 验证显式范围。子进程启动只使用 workerCwd。原 policy 继续由 PolicyProcesses 负责模式撤销和清理，原 tools binding/scheduler 调用完全不变。不将 policy 改为 danger-full-access。平台不调用同文件世界 sandbox.confine；所有模式均由专用原生provider创建独立UID任务。结果只报告 partial，中文执行说明明确真实cwd为/、工作区只能使用宿主bindings，不能声称原版direct fs、workspace-write完整支持。

平台仅一次性调用。不存在持久REPL、任意外部命令/shell、父目录FD映射或环境转发能力。调用真实工具仍须原工具权限/审批及中止逻辑。现有调用方若需要原版直接访问工作区，不应悄悄退化为此provider。

验证：ptc-platform.test.mjs读取真实固定原源码，检验摘要拒绝、binding与PolicyProcesses保留、构造拒绝、resolve引用/cwd范围、run拒绝非法范围，以及实际PolicyProcesses模式撤销使run取消并等待。只替换执行任务边界，不算设备/工具文件权限验证。subprocess.test.mjs另验证只读标记及原流控回归。尚需原tools无Key真实文件写读、read-only/越界拒绝、会话隔离、撤销期间队列和在途调用回收验证。

## 主DSH显式平台装配

仅EngineAbility的enablePrivateBroker=true为本轮主Node传入FD/代号时启用。bootstrap仅跨clearenv保留DSH_HARMONY_BROKER_FD与DSH_HARMONY_BROKER_GENERATION；缺一、格式错误或FD小于64均失败关闭。无两项环境时原cordis-min.yml默认启动路径不变。

资产归档新增：transport/subprocess-ohos.mjs、transport/subprocess-ohos-loader.mjs、transport/ohos-runtime-setup.mjs、scripts/patch-ptc-runtime.mjs，全部进入harmony-assets-manifest.json摘要。运行时按固定rc4源生成原包lib/ohos-index.js，保持相对process.js寻址；生成transport/cordis-ohos.generated.yml。两个派生文件只允许不存在时创建，已存在且字节不同则固定错误失败，不覆盖用户修改。打包排除ohos-index.js；generated overlay不在归档扫描目录。

Loader override中的name字段是匹配保护，不是重命名；平台覆盖因此禁用原subprocess/subprocess-local与ptc-runtime/ptc-runtime-node行，再插入独立平台provider文件URL。不覆盖DSH_HOME的cordis.patch.yml、用户profile、模型配置或凭据，不从这些文件取Key/token。用户自己的其他设置仍经原Loader应用；本轮显式平台选择只替换上述两项实现，并固定per-call/node-script，不擅自启用shell、terminal或persistent。

bootstrap-platform.test.mjs验证默认不写/半配置失败、不读取无关env、固定源与用户文件保留、生成冲突拒绝；直接执行原applyEntryPatches验证禁旧插新；用真实Cordis Context和SubprocessRuntime验证插件注册与dispose（Socket边界为固定替身）。主入口生命周期回归亦通过。完整原Loader启用平台PTC、真实tools权限及文件结果仍需真机，不以上述本机测试代替。
