# 独立 UID 的一次性 PTC 原生任务库

状态：独立隔离探针已真机完成40项协议/EOF/取消验收；本文件描述的新四通道生产组合已交叉编译并通过本机Linux集成，仍待鸿蒙真机验收。不可将探针结果当作生产组合通过。

## 相对探针的最小变化

- 新增独立 libdsh_ptc_task/child/shutdown/exit 四库；不覆盖探针。官方 ISOLATED+独立UID、固定process.js只读FD与SHA校验保持。
- stdout/stderr/control/nativeStatus 各独立socket。控制工厂使用公开Duplex+fs读写；stdout/stderr使用公开Writable+fs写，保留真实输出和原PTC输出限额处理。原JsonChannel/程序执行正文未替换。
- 移除测试fixture、布尔audit与JS退出事件；原生观察库使用Node SetProcessExitHandler与Start返回，固定16字节小端记录：magic=0x44534858/version=1/source=1或2/code。子进程能控制自身返回及其FD，记录不作为不可伪造的安全凭证。宿主官方退出回调决定真实退出与signal，缺少正常退出记录不能补0。
- 退出前原生shutdown登记的控制流及stdout/stderr，唤醒UV线程池中的阻塞读写；否则process.exit会等待未结束fs.read。Duplex销毁先真shutdown再等在途操作结束才close，避免FD复用竞态。
- 只接受显式cwd=/并在子端真实chdir检查。任何父workspace或其他未映射cwd都拒绝，不静默改成/。目录FD的fchdir/openat真机EACCES，暂不支持父workspace直接文件访问与persistent PTC。

## 宿主接口

模块 libdsh_ptc_task.so：

- launch(installedRoot,cwd,maxMessageBytes,heapMb)：返回正PID或负错误；并发容量8。maxMessageBytes为1..134217728整数，heapMb为16..4096整数。参数只生成固定启动argv，不接受shell、任意脚本或任意Node参数。负返回发生在创建前或官方创建失败。
- status(pid)：只返回pid/exited/signal，不消费任何流。
- read(pid,index,maxBytes)：返回bytes/eof/error；index 0控制、1标准输出、2标准错误、3原生状态；maxBytes为0..65536，0只查询已知EOF，不调用read(fd,0)。EAGAIN/EWOULDBLOCK返回空bytes、error0。Driver必须分别按credit调用，原生状态另用固定小预算。
- write(pid,bytes)：最多65536字节，返回实际写入数；0表示稍后重试。调用者处理短写并限制队列。
- end(pid)：真实SHUT_WR，不伪造EOF。
- stop(pid)：仅允许当前登记且未退出的PID。
- release(pid)：必须官方退出且四个流真实观察EOF，成功1，未满足0。

子端clearenv后只写固定启动所需内部变量；原脚本开始前移除FD/库路径变量并沿原脚本清空程序环境。原生关闭桥由入口一次登记FD，JS API不接受任意FD。

## 构建与验证

harmony/tooling/build-ptc-task.ps1 接收 NativeSdk、NodeSource、NodeLibrary、OutputDirectory；不得提交签名、产物或本机绝对路径。脚本从ptc-loader.cjs生成固定C字串头，Node API插件显式DT_NEEDED libnode，禁止链接ArkTS NAPI。C++退出观察另需libc++_shared，与打包的Node ABI一致。

已有本机验证：真实socketpair的200KB往返、强制短写、暂停读背压、真实半关闭、在途read取消；生产loader原ready/log/done协议、真实stdout/stderr、process.exit(7)原生source1记录与退出回收。Linux测试仅替换测试FD注册，不证明鸿蒙组合通过。

待真机：四流credit/背压、observer加载、真实根cwd与heap限制、正常/throw/reject/exit7/超时取消回收、连续并发及会话集成。用户workspace工具调用须留在父端授权broker，不能以本库成功代表shell/任意插件/直接workspace访问已支持。

## 继承标准流与公开嵌入入口

独立UID下已验证继承socket的read/write/shutdown可用，但元数据fstat/getsockname/getsockopt返回EACCES。Node Start默认初始化stdio会fstat(0..2)，非EBADF错误导致ABORT；退出ResetStdio也有相同假设。不能通过吞掉真实stdout/stderr解决。

新增libdsh_ptc_embed使用公开InitializeOncePerProcess(kNoStdioInitialization,kDisableNodeOptionsEnv)，保留Node自行初始化平台，通过InitializationResult.platform()与CommonEnvironmentSetup建立环境、LoadEnvironment运行固定引导器、SpinEventLoop及Stop/TearDown结束。真实1/2持续指向父授权socket。此候选已编译，仍需独立UID真机验收。依据：[Node 24.2嵌入API](https://nodejs.org/download/release/v24.2.0/docs/api/embedding.html)及同版本公开node.h。

使用pointer compression的Node库时，embed与exit这两个直接Node/V8 C++桥必须与构建配置一致；当前候选需要V8_COMPRESS_POINTERS、V8_COMPRESS_POINTERS_IN_SHARED_CAGE、V8_31BIT_SMIS_ON_64BIT_ARCH、V8_EXTERNAL_CODE_SPACE布局宏，不能与baseline退出观察库混用。build-ptc-task.ps1的V8AbiDefines参数必须来自目标库真实构建配置，不能猜测。纯Node-API关闭桥仍须组合验收，不因ABI稳定声明功能已通过。
