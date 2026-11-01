# 父宿主私有broker状态机

ParentBroker为纯TypeScript，不依赖Node Buffer/net或浏览器AbortController。注入Codec（严格UTF8、canonical base64）、TaskDriver、writeTransport短写函数及allowSpec准入函数。ArkTS接线时使用SDK编码器与原生库适配；本文件尚非ArkTS编译验收。

调用accept(bytes)接收分帧数据；周期pump()推进短写ACK、按额度读流、退出/回收及传输输出队列。writeTransport返回实际字节数，0需下轮重试。每流最大64KiB信用、帧1MiB/输出队列2MiB。

TaskDriver.start(spec,Cancellation)异步返回Task或显式StartFailure{startFailed:true,reaped:true,code:固定码}。后者必须已确定从未创建或已回收资源；普通Promise拒绝视状态未知，断连且settled失败，不发spawnError reaped:true。Cancellation支持aborted/subscribe；取消后迟到Task仍停止回收。

Task.read(stream,maxBytes)非阻塞，EAGAIN为空且eof=false；仅真实EOF可true。maxBytes=0绝不能调用read(fd,0)并把返回0冒充EOF，必须用已知EOF或返回false。writeControl返回实际字节数，完整片接受后才ACK。endControl半关闭。stop为幂等请求，pollExit返回真实退出事实。reap必须等待官方退出并释放任务所有资源，成功后才发送reaped。driver若无法保证不得resolve。

断连调用disconnect，保留对象并await settled，直到所有异步启动及回收完成；未确认资源或reap失败settled拒绝，不能丢弃对象声称停止成功。正常exit只在三流EOF后发送，done与reaped保持不同阶段。未知signal/帧/代号/credit失败并请求回收。

测试parent-broker.test.cjs转译执行实际源码，验证分片、信用、短写、先stop后spawn、断连迟到回收、明确启动失败、回收失败、普通启动拒绝未知及非法父输入拒绝。使用可控TaskDriver替身，不替代Harmony原生资源验证。未连接EngineAbility或设备。

## 正式宿主接线候选

`generate-host.cjs <typescript模块路径>` 从唯一 parent-broker.ts 生成 app/ohos/entry/src/main/ets/engineability/broker/parent-broker.js 和声明。生成 JS 已通过本机 SDK es2abc API26 字节码编译；不会把 Record<string,any> 等动态协议解析代码复制为第二份 ArkTS 状态机。改核心后必须重跑生成脚本。

新增 HarmonyBrokerHost.ets 注入 SDK util 编解码，原生 write 每次最多64KiB、每轮最多4次read，10ms泵进。父传现有 native broker handle 和相同 generation；仅在子端FD交付后 start。关闭须 await shutdown()，它先取消所有任务并 await core.settled()，最后关闭连接；回收失败保留拒绝，不当作已停止。

新增 HarmonyTaskDriver.ets 对应 libdsh_ptc_task.so 分流API：每流read按credit限制，0额度不消费；nativeStatus固定16字节magic/version/source/code，官方signal与observer码分开。正常退出必须有observer来源1或2，signal0无记录为失败。双回调一致和四真实EOF后release及forget。取消只回收自己PID，最多等15秒后明确失败。

97真机已确认父目录FD在独立UID下stat/fchdir/openat/output均EACCES。因此driver只接受字面cwd='/'，child仍须真实chdir('/')检查；其他cwd明确拒绝，不会假称workspace-write实现。只允许固定oneshot argv、空envSet（原入口envUnset由child清空环境实现）；其他自定义环境、shell和persistent均不支持。原生stop当前使用官方Kill，属于即时取消，不承诺graceMs软信号阶段。observer通道不宣称抵抗同任务恶意代码自行伪造；官方退出状态另行确认。

四组 harmony-broker.test.cjs 执行真实ETS源码，仅模拟SDK/native边界，已通过。仍需父统一HAP进行完整ArkTS类型检查和正式端到端真机测试；本机测试不是设备验收。
