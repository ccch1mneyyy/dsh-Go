# 固定 rc4 网页界面恢复

本轮只恢复原网页的 18 个 UI 条目，并显式禁用 `entry-customization`。没有启用终端、插件安装器、系统目录选择、Office 转换或系统应用启动后端。

## 配置范围

生产唯一覆盖清单仍是 `harmony/plugins/dsh_runtime_ohos/assets/platform-diagnostic.patch.yml`。

- 基础 11 项：`ui-renderer`、`ui-settings`、`ui-theme`、`ui-layout`、`ui-session`、`ui-conversation`、`ui-sidebar`、`ui-sidebar-right`、`ui-workspace`、`ui-input-trigger`、`ui-chat`。
- 主要控件 7 项：`ui-commands`、`ui-model-selection`、`ui-permission`、`ui-approval`、`ui-user-questions`、`ui-brand-official`、`ui-settings-account`。
- `ui-permission` 的真实包是 `@deepseek-ai/dsh-client-ui-permission-presets`，控制 DSH 工具许可，不是设备系统权限。
- `entry-customization` 依赖被禁用的 `ui-plugin-manager` 提供的 `pluginNavigation`，不是主聊天必需项，因此显式禁用，避免原网页对 pending 条目的启动审计失败。

原网页不是只有静态 index。固定 rc4 的 `dsh-client-ui-renderer/lib/client.js` 提供 `uiRenderer`，`dsh-client-ui-layout/lib/client.js` 注册 `root` 槽位；两者原先均被禁用。`dsh-web-frontend/dist` 的启动审计要求每个 browser entry 为 active，缺失硬依赖不能当作正常启动。

## 可重放验证

固定资产必须来自官方 Android 1.0.2 APK 的 rc.4 树，参见 [资产准备说明](../tooling/prepare-dsh-assets/README.md)。不执行 npm 生命周期、DSH CLI 或模型。

```powershell
node harmony/tests/runtime-lifecycle/web-ui-restoration.test.mjs "$RuntimeAssets/opt/dsh/node_modules" "$OutputRoot/web-ui-tests"
```

测试验证：

1. 18 项精确恢复，21 项危险或未实现边界继续禁用，没有重复 id。
2. 使用原 Cordis Context 和原 ClientModuleRegistry 读取固定 profile 与客户端资产，18 个 UI 包全部在图中，受限项不进入图。
3. 18 个节点半部在无用户空上下文可注册；真实客户端导出的字符串 `inject` 列表均有图内提供者。用原 Cordis 检查依赖门：缺服务时不激活，提供映射夹具后可满足。
4. 用全新小输入运行正式 packager，核 ZIP 的 `transport/cordis-min.yml` 等于仓库唯一清单，且清单摘要正确。

服务值在依赖门测试中是空对象，未执行 browser apply、DOM 或 RPC。此测试不能宣称网页实际全部 active、目录选择成功、账号弹窗成功或聊天生成成功。

## 唯一打包入口

`package-runtime.py` 已把仓库平台清单映射成 ZIP 的 `transport/cordis-min.yml`，不读取 source 中旧 transport 副本，不需要另一份 UI 覆盖清单。沿用唯一入口：

```powershell
python harmony/plugins/dsh_runtime_ohos/package-runtime.py --source "$RuntimeAssets" --output "$OutputRoot/dsh-runtime.zip"
```

`RuntimeAssets` 必须是已经核验 `PREPARED-SOURCE.json` 的固定清洁导出目录；不使用设备 home、旧 runtime-installed 或诊断树。重新打包后核完整 ZIP 摘要，再由主流程同步安装清单的版本与摘要。此步骤本身不自动覆盖 App 内置 ZIP、不构建 HAP、不签装设备。

## 原网页只读验收

只记录布尔或计数，禁止保存页面正文、完整地址、全量 boot 对象、storage 或错误原文：

- `[data-dsh-boot]` 启动壳应退出；`[data-slot="root"]` 和 `[data-slot="main"]` 应存在。
- 主会话槽位 `[data-slot="main.conversation"]`、`[data-slot="conversation.composer"]` 和真实输入 `[data-composer-input]` 可用于验证主界面已挂载，不读取文本内容。
- `[data-slot-error]` 应为零；还应核 `__DSH_BOOT__.entries` 包含所需 UI id。包名存在只代表资产图，不代替 DOM 和启动审计。
- 固定 rc4 的 boot 错误在内部 catch 后渲染，因此 pageerror 为零也可能启动失败。只查询 `[data-dsh-boot] ._failed_u7vgf_72` 或 `._failedTitle_u7vgf_79` 的存在性，可映射为 `BOOT_FAILURE_VISIBLE`；不要读取错误文字。CSS hash 必须与本轮固定发行资产匹配。
- pageerror 仅映射固定码，例如 `BOOT_ENTRIES_INACTIVE`、`ROOT_REGISTRATION_MISSING`、`SLOT_SCOPE_ERROR`、`JS_RUNTIME_ERROR`、`UNCLASSIFIED`；不输出 message/stack/URL。服务名只能从固定白名单报告。

终端、pluginManager、系统目录 picker、Office 和系统应用启动维持独立任务。typed Remote namespace 的存在只是协议注册，不能当作对应 Host 功能可执行。

## 正常包 141 实际结果

修复前正常包 135 在独立浏览器访问平板本机服务，HTTP 200 但启动失败标记可见，root/main/composer 均不存在。修复后正常包 141 已编译、签名、覆盖安装并重新启动：同一只读浏览器核验中 root、main、main.conversation、conversation.composer 和实际输入节点均存在，启动壳及失败标记消失，slot-error 和 pageerror 均为零。未发送模型请求，不记录页面正文或完整地址。

此结果验证真实平板 Host 所提供的原网页，而不是仅资产图或静态 index。平板原 Flutter 入口也已打开一个系统 Web 组件，但没有通过其辅助树取得可验证的网页输入节点，不能据此称所有 WebView 交互均通过。插件安装、目录 picker、终端、Office 及其他未恢复项目仍不支持。
