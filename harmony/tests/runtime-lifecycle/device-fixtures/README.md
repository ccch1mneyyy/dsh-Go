# 真机验收夹具（不进入正式运行包）

这些脚本保留119/119b的真实验收路径。正式 package-runtime.py 不打包它们，正式启动器不读取测试环境开关，也不注册模型fixture。

## 独立测试HAP注入

1. 先按正常流程生成正式runtime ZIP；用本目录 inject-test-runtime.py 的 --production-zip、--test-zip 生成不同路径的测试ZIP。脚本更新全部资产摘要，不覆盖正式包。
2. 仅在独立测试HAP构建副本中替换runtime ZIP并同步版本、摘要。临时Ability/入口须明确设置 DSH_HARMONY_REAL_TOOLS_PROBE=1，提供既有私密broker，并仅使用新建 engine-tools-probe-数字 测试根目录。不能连用户主数据目录，不能读取或同步已存API Key。
3. 测试bootstrap快照部署到 transport/run-loopback-smoke.mjs，其相对生产helper及scripts导入保持正常运行包布局；四个夹具均同目录部署，因此相互相对导入无需改变。快照不是本地独立启动的应用入口。
4. 首次依次运行能力枚举、真实文件工具和无凭据回环SSE fixture对话；只接受安全报告枚举、布尔和计数。fixture模型不是付费DeepSeek调用。能力与工具句柄清理后才开始对话。
5. 真正停止并重启测试引擎，保持同一测试根；父读取新报告前只删除固定 local-acceptance.json，保留 conversation-fixture.json。再次启动后仅冷读；differentProcess和两项持久化检查必须真实为true，不能接受上次旧报告。
6. 测试后恢复正式HAP，覆盖安装保留用户数据，不卸载清数据。临时Ability和测试ZIP不能进入PR正式资源。阻断其他模型的钩子跟随整个fresh测试上下文销毁。

patch-ptc-runtime-diagnostic.mjs仅供测试，保留临时结构化kind观察点；正式补丁没有此入口。所有诊断均不得写入原始错误、路径、数据值、凭据或认证URL。

测试结论仍须按运行证据判断：脚本本身及syntax通过不能证明设备通过，也不能证明Android全部功能已对齐。
