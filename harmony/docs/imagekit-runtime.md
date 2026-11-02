# 鸿蒙本机图片后端与验收

有限 ImageKit 后端已接入正常151，复用原 Flutter 页面及 DSH 附件协议，不新增系统权限或调度器，不改变用户图片并发配置。源 ICC 的后续能力仍须单独验收。

## 行为与边界

只有`process.platform === 'openharmony'`分支加载新helper。其它平台保留原Sharp函数、质量梯度和`request-image-v6`缓存键；可逆源码测试必须精确还原原字节。原AttachmentStore SHA固定为`cd39685581b4573a453c6126f8ce73da0bf1257c378827ebb431d6d4064f7662`，任何未知原包均在生成ZIP之前拒绝。打包器只在新包内改写副本，不修改提供的原DSH目录。

新分支使用`request-image-imagekit-candidate-v2`隔离缓存。保留原admission、限额、批量失败不发布部分结果、SHA摘要与EEXIST赢家复核、缓存损坏恢复、预算耗尽保留最小结果、取消与SharedRequest协议。排他发布调用仓库已有`libdsh_publish.so`，使用RENAME_NOREPLACE；不回退copyFile冒充原子发布。

同一helper singleton用已有Promise tail串行实际后端工作，失败不会poison后续任务，关闭排在先前工作之后；用户imageCompressionConcurrency仍为原1…8上界。原CompressionLimiter、C全局最多2任务和worker最多2输入均不扩大。取消不丢弃native Promise，等工作settle后再释放资源；不把未完成任务当作已关闭。

生产bootstrap把`DSH_HARMONY_DURABLE_ROOT`精确设为本次`fresh`。helper用`path.relative`验证home／源／目标是严格后代，拒绝root本身、`..`、绝对相对结果及相似前缀兄弟目录。bootstrap不再对AttachmentStore做启动时link→copyFile替换；补丁在打包时完成。资源marker同步升为`scriptver-151`，促使旧引擎资产重新解压，用户数据仍用原dataRoot。

格式限PNG／JPEG／WebP／GIF。原20MiB输入、64MP、8192边长上限、单帧／格式／尺寸／8bit／SDR／sRGB／alpha／完整解码及输出复验均保留。未知元数据和源ICC仍拒绝。只有已经系统归一化的新编码输出可走既有精确ICC清理，随后strict解析和native完整复解码；清理不用于原输入。不承诺任意profile、HDR或未知颜色格式。

## 正规目录

- `harmony/plugins/dsh_runtime_ohos/native/imagekit.c`：原已验C源码，Node NAPI异步工作、只接内存，不接用户文件路径。
- `assets/imagekit/`：原backend／parser／worker／ICC helper；附件桥`ohos-imagekit.mjs`只改正规transport引用。
- `scripts/patch_imagekit.py`：固定SHA及九个唯一锚点，保留原非OHOS源码。
- `package-runtime.py`：固定源码补丁、新helper与五个transport模块、补丁来源摘要均入清单。
- `harmony/tooling/build-imagekit-addon.ps1`：显式SDK／Node／输出参数，无机器绝对路径。
- `harmony/tests/imagekit/`：固定小合成图与便携宿主测试，不含HAP装配框架、ICC研究原图、日志、密钥、原DSH包、SO或ZIP。

现有`native/publish.c`、`assets/persistence-publish.mjs`及`harmony/tooling/build-publish-addon.ps1`保持不变，继续使用同一签名发布库。

## 构建与许可证材料

```powershell
./harmony/tooling/build-imagekit-addon.ps1 -NativeSdk $NativeSdk -NodeSource $NodeSource -NodeLibrary $NodeLibrary -OutputDirectory "$OutputRoot/imagekit"
```

参数由操作者明确提供。NodeSource须与实际运行的Node／libnode匹配，SDK需提供现有代码使用的ImageKit Native API及GetAlphaMode。脚本只构建独立addon，不编译Node，不复制到App libs，不构建或签名HAP。输出仍叫`libdsh_imagekit_candidate.so`以保持已验ABI／SONAME；这是稳定文件名，不代表可跳过验收。

必须验证AArch64、SONAME、DT_NEEDED含libnode.so且不含ArkTS libace_napi。代码通过`node_api.h`使用Node NAPI8，SDK图像头只声明系统C API；不能因ImageKit头间接包含ArkTS NAPI而改链libace_napi。系统ImageKit／颜色库由设备提供，不复制系统库。保留仓库LICENSE、原DSH各包许可证与Node／SDK外部头的原许可材料；打包器继续包含原包许可证，不把第三方库源码或二进制悄悄迁入本目录。

## 可重放宿主验证

```powershell
python harmony/tests/imagekit/test_package.py --modules-root $OriginalModules --output-root $TestOutput
node harmony/tests/imagekit/host-contract.mjs --modules-root $OriginalModules --sharp-module $HostSharp --output-root $TestOutput
```

`$OriginalModules`为只读固定原DSH node_modules；`$HostSharp`显式指向宿主Sharp模块；`$TestOutput`是独立工作目录。输出只放该目录，子进程HOME／DSH_HOME均指向新合成测试树，不启动CLI、模型或账号。测试运行Node24及Python，Sharp只作为宿主C ABI替身，不进设备包。若只拿候选overlay测试，Python另传`--baseline-repo $BaselineRepo`，在工作目录合并原有未改资产后打包；不合并回生产。

Python四组覆盖精确逆变换／未知SHA拒绝、包内清单和helper、许可保留和固定敏感文件排除、错误源不生成输出、资源marker与窄durableRoot／便携脚本。Node实际加载固定原Cordis／Tools／Store，非OHOS原Sharp路径真实执行且不加载helper；模拟OHOS合法门通过原31项工具矩阵，另验缓存无native、赢家／损坏缓存／质量梯度、一个waiter取消另一个成功、全取消不晚发布、关闭settle／重开、精确边界、错误redaction与失败恢复。模拟门只改隔离内存中的两个精确平台表达式，不篡改process.platform。

## 当前证据与发布门

独立142设备已通过C／worker／backend固定六图和取消／边界。148设备原工具schema2已通过31检查和六图并发／config8；profileTested、modelRequestSent、credentialsRead、userImageRead、productionIntegrated均false。该结论不等于正常Flutter原UI端到端附件验收。

150随后已在真实设备通过控制图＋27份C编码／ICC清理后产物的完整像素与八方向检查；Node settled、SHA、白名单清理、监听／timer移除及28源／28位图释放全过，productionIntegrated仍false。这只覆盖固定研究样本，本候选继续拒绝源ICC。有限profile策略和未来v3缓存另行审查与真机重测，不混入本v2基础迁移。正常包正式接入前，主流程须审候选diff、核签名库／包SHA、使用固定非私密图片完成正常原UI附件／原工具／缓存冷读／取消及重启回归。没有这些新正常包证据时，不宣称生产已完成图片适配。

回退由主流程保留的正常包和源码checkpoint执行；不删除用户附件或配置。若回退至旧运行时，资源marker也需对应，避免旧缓存资产误复用。


## 正常151原协议与界面验收

2026-11-02，正规源码重新运行四组打包测试、原工具31项、五项语义和三项取消／关闭检查均通过；从清洁固定原资产运行同一宿主矩阵也通过。便携 addon 构建脚本已实际交叉编译，AArch64／SONAME／Node NAPI链接核对通过，输出 SHA 与已验 b398ac84… 库逐字节相同。Node未重复构建。

正常151构建29.5秒、签名并覆盖安装保留数据，原abilities及旧原生库保持一致，无图片测试入口。真实本机认证与账号保持通过；仅对新建的自有测试会话发送固定PNG故意声明JPEG，原vision gate之后的完整图片检测返回 IMAGE_TYPE_MISMATCH，没有用户消息／turn写入；未引用附件按原授权拒绝。测试client曾用错物理工作区及历史地址字段，修正为实际应用命名空间和原schema的sessionId后整轮通过，没有用替身结果覆盖实际失败。

用户已授权API测试后，使用已有deepseek-official／deepseek-flash完成一次合成32×16 PNG的正常图片prompt，原user image引用、助理回复和turn/end均通过；session/attachment暖读的SHA、尺寸、mime、字节数及固定输入逐字节匹配。切换原Flutter到本机并打开该自有会话后，缩略图、回复和图片预览实际渲染。随后完全force-stop，确认旧native进程不存在，新进程及启动时间变化，同一图片冷读再次通过，不重复发送模型。测试不读取或输出API Key、账号token或用户图片。

该正常协议验收没有从公开RPC直接操纵私有请求缓存；缓存、预算、取消settle及并发的结论来自独立148原Tools／Store真实31项，不能把attachment暖冷读混称为cache生命周期全重测。源ICC与未知metadata仍拒绝，更多格式／profile的能力不由本结果自动放开。
