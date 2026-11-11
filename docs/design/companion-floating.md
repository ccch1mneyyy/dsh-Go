# 悬浮伙伴：同一宠物窗口的第二种画法

> 未真机验证。2026-11-11。基底 1a2af92b7cfbd5958173f57949d26f2dd8e060e8。
> [English](companion-floating.en.md)。这是 7010 → 7020 → 7021 → 7030 的共同合同；7030 还依赖工坊 App 链中的 CompanionPackStore 完整性与变更通知。整组与本机接线一起验收，不把前半当作独立功能。

## 结论与证据边界

默认仍为像素宠物。用户明确选择伙伴后，PetOverlay 继续拥有唯一窗口、服务、显示策略、手势、吸边、气泡、问一句、今日隐藏和截图隐藏。PetView 容纳一个 WebView；没有第二个悬浮服务或菜单。placeMenu 原文不改。

Application context 的 WebView、窗口硬件加速和透明 WebGL 是有官方接口支持的候选方案；并未证明 Android 8–16 所有厂商组合都成立。非 Activity context 不提供部分 Activity 功能，本舞台不使用 JS 对话框/自动填充。实际 isHardwareAccelerated 为假即进入一次恢复/像素回退。[A1–A3] 系统强制隐藏 overlay 是否及时送达可见性回调，仍须设备证据，不能据此承诺未知隐藏期间一定释放。

**完整功能目前有一个已证实的本机接线阻塞：伙伴小屋尚未保护其 WebView renderer 退出。** 小屋后台只暂停 JS，实例仍可能与悬浮窗共享 renderer；Android 要求每个受影响实例分别处理退出。锁定 webview_flutter_android 4.14.1 的原生 WebViewClientImpl 没有覆盖该回调，不能靠浮动实例返回 true 保护另一实例。[A4、A5] 下述“小屋接线合同”闭环前，完整崩溃恢复保证标为 BLOCKED。不能把它写成仅差真机确认。

## 选择、能力与错误

PetPrefs 保存 pet.overlay_renderer（pixel / companion）及 pet.overlay_framing（一个 JSON，zoom 和 y 同时写入）。旧值或未知模式为 pixel；zoom 须有限且在 (0,4]，y 在 [-1,1]。默认 zoom=0.9、y=0，是可配置的工程取景值，不是可用性测量结论。

设置只加一个现有 SettingsSwitchTile。读取相同 application-support/companion 目录，用 unavailableReason 检查固定 runtime 聚合摘要、角色入口、引用和 moc 头版本；不自动下载，不把检查成功当作 Core/GPU 已运行。未安装或不完整时不可选；已经选中时仍允许关闭。

CompanionFloatSession 按选择代与 store revision 丢弃迟到的检查/页面。像素默认不解析包、不开 socket、不创建 WebView。选择期间页面由随机令牌的 CompanionServer 提供；Dart 向原有平台通道发送 configureCompanion(page, notice)，关闭发送 page=null。确认只表示原生接纳，不表示首帧已显示。原生状态增加 companionRendering、companionFallback、companionProblem；未选择时不改变原来的像素状态 map。

setup 的 MissingPluginException 返回 companion_native_unavailable；PlatformException 返回 companion_channel_failed；文件、socket 错误分别为 companion_storage、companion_server_failed。错误只含稳定码，不含令牌 URL、文件路径或原始异常。原生启动、硬件、协议、上下文和 renderer 故障也只传固定码。

CompanionPackStore 同根实例共用队列、revision 与 beforeChanges。变更先公布 revision 并等待 reader 停止，再移动目录。float hook 先使旧代失效，串行等待原生销毁确认与 server 请求清理；hook 内不能再 await store 操作，否则会自锁。关闭失败仍保留页面清理责任并阻止目录变更。provider 只保留工厂，不长期缓存失败 Future；新的显式选择或退出后重新进入设置可重试，活动 Session 保留成功的 store。旧代即使晚取得页面，也只关闭自己的页面，不把 capability 交给原生。

CompanionServer.close 拒绝新处理、强制关闭 socket，并等待已跟踪 handler。异步 asset/type/length 读取恢复后先看 closed；旧 handler 不得在包替换后重新打开新目录中的文件。小屋也须按同一 reader 合同接线，见后文。

## 舞台协议与资源

页面使用 mode=float；房间模式保留原路径。float 不创建 scene 的 2D context，不画背景/物件，不接房间触摸、语音、道具、昼夜计时或自动情绪事件。舞台、WebView 和窗口均透明。

每次提交间隔至少 1000/30 毫秒，使用 FrameGate，不沿用房间的提前阈值。设备刷新率与调度可能使实际帧率更低，上限不等于稳定 30fps。float 的 DPR=1、maxTexture=1024、maskSize=512、antialias=0，是成本控制选项；不是内存或功耗保证。模型像素读回每次提交执行，复用 RGBA buffer，只有边界变化才向原生发消息。

原生 → JS：petState(state, reduceMotion)、freeze、thaw、dispose。JS → 原生：floatReady、floatBounds(width,height,bounds)、floatError(code)、floatResume。bounds 的 right/bottom 为开区间，null 表示全透明。ready 只说明模型建立，不保证异步 shader 已完成。

折叠/变暗 freeze 在 ready 且收到第一个非空像素边界后才暂停 rAF，保留已画出的图；否则冷启动就变暗可能冻结在空白并触发超时。加载期间取消折叠不再冻结。屏幕关、真正隐藏、省电和销毁走释放路径，与保留图像的 freeze 不同。reduceMotion 随 petState 动态更新，停止已排动作，无需重载页面或重置故障预算。

dispose 幂等：先标记失效、abort 自有 fetch、停止 rAF，再 release 模型，最后尝试 WEBGL_lose_context；异常不能阻止原生收到固定错误。加载器在 await 后核对失效，晚到 bitmap 必须 close，不继续创建纹理；晚到 motion/physics/pose 不能再分配模型资源。模型 release 本身不证明所有 app 创建纹理或 Framework 静态 shader 都已释放。固定 Framework 5-r.5 的 generateShaders 是 void，内部独立异步 fetch；它没有接本页 AbortSignal。此时不能安全地把全局 dispose 当同步取消。最终清理由 context loss 与原生移除/销毁 WebView 完成。[A6–A8]

## 状态映射

只采用 character.json / adapter 明确给出的 emotions/actions。不存在的动作保持待机，不借房间通用动作表冒充模型能力；同状态重送不反复触发动作。

| 宠物状态 | 已声明时的表情 | 已声明时的一次动作 |
|---|---|---|
| idle | calm | 无 |
| thinking | confused | tilt |
| working / juggling / sweeping / carrying | calm | nodSmall |
| attention | happy | nod |
| notification | worried | lookUp |
| error | sad | shake |
| sleeping | sleepy | yawn |
| waking | calm | stretch |

## 一个窗口内的几何与触摸

内部 WebView 视口固定，以 EXACTLY 测量；窗口只取实际 alpha 非零像素的包围盒。WebGL 原点在左下，报告先转左上；原生按 buffer/view 尺寸比向外 floor/ceil。包围盒外点击交给下层应用，盒内透明孔洞仍属于此窗口，不声称逐像素穿透。

设窗口坐标 P、旧包围盒左上 B、新左上 B'，更新 P'=P+B'-B；因此内部视口原点 P-B 保持不动。同步修正 dragStart/dropAt，拖动时仍按原安全区域 clamp。fullReach 是固定视口相对裁切窗口的范围，让原来的吸边/菜单/气泡读取同一 PetFrames 合同。这个恒等式不是所有密度/屏幕/厂商场景的设备证明。

启动尚无真实边界时窗口 alpha=0 且 NOT_TOUCHABLE；不能让透明完整视口挡住其他 App。首个非空边界之后恢复触摸。后来全透明时使用不可触摸、alpha=0 的最小窗口；仍继续渲染等待再次可见。15 秒无首个非空边界视为启动失败，此数值是工程超时。

PetView 父层截获手势，WebView 不聚焦、不参与单击/长按/拖动的语义；继续用 showMenu，不改 placeMenu。视口初始高度为选定像素宠物高度的四倍，经 640 view px 和扣除两边吸边留白后的安全高度裁切，宽为其 0.75 倍并受同样扣除留白的安全宽度约束。7021 修正了原先只扣系统 inset 的上限：当视口占满安全高度时，EdgeSnap 仍在顶端加一份留白，实际下沿会越界；新上限让整个 fullReach 都能放入既有吸边区。系统报告的区域若在两边留白之间连一像素都放不下，就暂不创建伙伴 WebView，保留像素路径，等待后续有效区域，不消耗故障重试。默认取景仍可调，小屏/旋转与厂商仍需实测。

## 显示与故障生命周期

选择有效、未回退、策略为 SHOWN、屏幕 interactive、系统报告 shown、非截图、非省电时才创建 renderer。已知隐藏、今日隐藏、暂停、熄屏、截图和省电会销毁，恢复时新建。WebView.onPause 不保证停止 JS，不能只靠它；也不调用影响所有实例的 pauseTimers。[A1]

故障预算属于选择的页面 capability，不属于每次窗口创建。第一次当前代 context loss / renderer gone / 加载失败重建一次；第二次回像素，提示一次。正常 hide/resume 不重置预算，重复旧代消息不消费预算。显式关闭或换包/取景产生的新 capability 开始新周期。故障 WebView 不复用。[A4]

**不承诺保活收益。** 此功能复用已有服务与窗口；没有“加一个窗口提高后台存活”的保证。

## 需要本机做的：小屋与页面接线

1. 在 app/lib/ui/companion/companion_stage.dart 设置 navigation delegate 后、首次 load 前，用现有 IslandPlatform.attach/guard 保护当前 Android WebView id，并核对 attach 的布尔确认。WebViewGuard.attach 的 void 完成不能证明 attach 成功；不需要升级插件。
2. renderer 故障只处理当前实例/代；撤销 ready、timeout、JS 回调，移出 WebViewWidget 后销毁捕获的旧 id，关闭该实例 server。异步闭包不能读取已被新 controller 替换的可变 id；旧 start 在各 await 后核对代。复用现有宽广播 guard 时明确其行为，不额外消费 float 预算。
3. 小屋的活跃 reader 同样注册 store.beforeChanges，移除/销毁自己的 WebView 并关闭 server 后才允许替换包；hook 内不进入 store 队列。安装/删除过程中旧读者不能继续持有或读取被替换目录。
4. 小屋按既有错误/重开流程创建新实例，不能 reload 已死亡实例。仅后台 pause 或“通常不共存”不能取代每个受影响实例的 guard；前后台切换有异步交错。
5. 补准确中英文产品文案：“悬浮窗里显示：像素宠物 / 小屋里的她”、不可用原因、一次像素回退提示；当前最小设置复用现有文案，不在本波改 l10n 生成源。取景的更完整 UI 归本机，偏好接口已提供。
6. 按项目要求用 Dart formatter、analyzer、全量 CI 和受影响 golden 完成验证；不手改生成物。若舞台 corpus 的固定摘要检查受影响，由本机按原工具重录、审核，不把缺 Core 的 mock 当 corpus 实跑。

以上生命周期 UI 文件不在本波获准的“最小设置/入口”改动范围，因此列合同，不通过搬文件绕开限制。

## 模拟清单与定论方法

已执行的 Node 测试覆盖纯帧门/alpha/映射，并在隔离 VM 中执行真实 stage.js 控制流：float/room、首次冻结、动态 reduceMotion、取消、晚到 bitmap/motion、release 异常与 context loss。Core、WebGL、fetch/窗口边界被替代；通过不证明实际渲染。JVM 与 Dart 测试已写但未在沙箱运行；准确数量与补丁 SHA 见交付证据。

本机跑策略/几何 JVM、偏好/通道/session/store/server/widget Dart，并跑现有回归。故障时序须用屏障控制先后，不能只靠连续切换碰概率。必须覆盖切像素时检查晚到、原生确认晚到、换包期间关闭失败、store 工厂重试、被杀重启、旋转、所有菜单/气泡/问一句行为和像素默认路径。

设备记录构建 SHA、Android API、厂商/GPU、WebView provider/version、实际窗口类型、密度/刷新率。覆盖 Android 8/10/12/14/16 可取得的组合并明确缺项；验证硬件加速、透明、矩形触摸、小屏/大字体/横竖屏、熄屏、省电、今日隐藏、截图和系统强制 overlay 隐藏。验证“小屋→Home→浮动”与网页/图表共存的 renderer 故障；宿主必须存活，首次至多重建一次，同选择代再次故障仅一次回退提示。未执行这些设备步骤。

内存同时记录宿主与 renderer PSS，含加载峰值、稳定态和销毁后，不能只量 Dart heap。估算纹理下界为 4×宽×高，另加 mip、mask/FBO、读回和 Core；不是实测上界。功耗采用同设备/亮度/网络/温度、固定角色的 pixel/float 配对 30 分钟，每组至少三次，分别 idle 与动作，记录帧率、温升、电池/能量统计。没有这些测量，不给省电比例或驻留内存数字。

若直接透明 WebView 被设备证伪，保持像素回退并交 owner 选择方案。软件 Canvas 上 WebView.draw 不能当可靠 WebGL 位图替代，Chromium 明确列出软件绘制限制。[A9] VirtualDisplay/SurfaceTexture 或原生 SDK 是需另行测量和许可评估的方案，不在本波自行替换。

## 一手资料

访问日期 2026-11-11；官方契约和固定源码不等于全设备验证。

- [A1] https://developer.android.com/reference/android/webkit/WebView
- [A2] https://developer.android.com/reference/android/view/WindowManager.LayoutParams
- [A3] https://developer.android.com/develop/ui/views/graphics/hardware-accel
- [A4] https://developer.android.com/reference/android/webkit/WebViewClient#onRenderProcessGone(android.webkit.WebView,%20android.webkit.RenderProcessGoneDetail)
- [A5] https://github.com/flutter/packages/blob/9854cd5607da4001f2dd3cbdcd6903202d28958c/packages/webview_flutter/webview_flutter_android/android/src/main/java/io/flutter/plugins/webviewflutter/WebViewClientProxyApi.java
- [A6] https://github.com/Live2D/CubismWebFramework/blob/198a3769c26ca3d7b600e932590433badd392edd/src/rendering/cubismshader_webgl.ts
- [A7] https://docs.live2d.com/en/cubism-sdk-manual/use-framework-web/
- [A8] https://registry.khronos.org/webgl/extensions/WEBGL_lose_context/
- [A9] https://chromium.googlesource.com/chromium/src/+/HEAD/android_webview/docs/software_draw_deprecated.md
