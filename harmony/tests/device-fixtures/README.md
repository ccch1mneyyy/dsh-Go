# 真机验收入口源码夹具（不编入应用）

此目录保存最终清理前的临时纯ArkTS入口、宿主测试分支、主native测试标记和旧Runner。正常App没有这些源码的引用，也没有ToolsProbeAbility exported声明。文件不能自动注册或运行。

- `entryability/ToolsProbeAbility.ets`：严格双bool/新fixture目录/独立endpoint，窗口创建后转发，安全报告白名单镜像。
- `engineability/EngineAbility-test-entry.ets`、`native/runtime_process-test-entry.c`：配套测试标记快照；生产文件已移除对应分支。
- `engineability/*ProbeRunner.ets`：固定无凭据验证源，保留其真实判断条件。
- `entry-tools-probe.test.cjs`：执行入口夹具真实ETS的VM回归，覆盖参数边界、报告schema和有界轮询；不证明设备测试成功。

执行：`node harmony/tests/device-fixtures/entry-tools-probe.test.cjs <本机typescript模块目录>`。生产生命周期测试仍位于`runtime-lifecycle/native.test.cjs`，旧BrokerRunner判断测试现读取这里的夹具；两者均已在清理后通过。

需要重新真机验收时，仅在独立测试包/分支按此快照显式添加入口声明和配套native后缀；使用全新测试目录、空凭据，禁止连接正常Flutter用户endpoint。还需测试原生库/类型及固定rawfile，不能把本目录当作可直接部署的完整独立应用。本次移除的17个测试so、8组NAPI类型、4个测试rawfile和旧主入口库已在D盘工作证据`final-cleanup-119`归档并保留库SHA清单，未丢弃二进制证据；这些本机产物不提交。

生产保留13个库，包括`libdsh_ptc_embed.so`。已核DT_NEEDED和当前生产源码的动态加载引用：正式Node/PTC/control/broker/publish/flock/require_builtin只依赖保留库或系统libc/C++/child_process/ArkTS NAPI；不会动态加载旧测试库。发布前仍需父统一干净HAP构建及正常UI最终验收。
