# 私有本机子进程通道 v1

仅主DSH进程和创建任务的EngineAbility之间使用。继承Unix socket不得传给执行用户程序的任务，不提供TCP监听或用户可选端点。

## 装配
`createOhosSubprocessProvider(SubprocessRuntime, { transport, generation, executable, bootstrapPath, allowCwd })` 返回继承原服务基类的Cordis插件。transport是已建立的Node Duplex Unix socket；generation是本次主引擎启动代号。父在Loader装配服务时加载，不在web ready后补注入。当前仅支持固定可执行标识及原一次性process.js，其他命令/terminal失败；不声称shell、cwd映射或workspace-write等价已实现。

## 帧
4字节无符号BE字节长度+UTF8 JSON；JSON长度1至1048576。每消息公共字段：`v:1,generation:string,id:正安全整数,type:string`。id在单连接递增，不传PID。旧generation、未知id、非法顺序、重复结果、未知signal失败并断开；父断连时必须取消并回收该代全部任务。

## Node发给父
- spawn：`spec:{kind:'ptc-oneshot',argv:[固定executable,'--max-old-space-size=N',固定process.js,帧上限字符串],cwd,envSet,envUnset,stdio:{stdin:'ignore',stdout:'pipe',stderr:'pipe',control:'pipe'},graceMs}`。graceMs整数0..30000。argv最后是PTC内层帧上限，不等于broker帧上限；原默认134217728允许拆包。cwd必须allowCwd严格返回true。envSet仅显式字符串，envUnset保留undefined删除语义；父不得通过JSON丢失删除项或隐式继承凭据。
- readCredit：`stream:'stdout'|'stderr'|'control',bytes:正整数`。spawned后每流初始65536，后续只补已消费额度；父不得超额发data。控制流被Node关闭后继续丢弃排空但不累积内容。
- write：`seq:正递增整数,data:canonical base64`，仅写control，每片最多65536字节；一个任务每次最多一个未确认片。父收到全部片并实际接受后才回writeAck。不能仅入无限队列就ACK。
- end：关闭control写方向；stop：请求停止受管范围，二者幂等。stop可能早于spawned，父必须记住取消并回收迟到PID；spawned后Node可重发stop。

## 父发给Node
- spawned：创建成功，可接收读额度与写入。尚未spawned时不得发data/ACK/exit。
- spawnError：`code:固定[A-Z0-9_]{1,80},reaped:true`；只能在从未创建或已经回收后发。done拒绝，但waitForExit成功。不要传异常正文。
- data：`stream,data:canonical base64`。不可超过对应credit。stdout/stderr/control全为二进制，不能中途按UTF8解码。数据帧不为空。
- eof：`stream`。只在真实read==0且所有之前字节发送后发，EAGAIN不是EOF。
- writeAck：`seq`，对应上面写入片；重复/错seq失败。
- exit：三流全部EOF/排空后发，`exitCode:0..255,signal:null`或`exitCode:null,signal:固定SIG名`。支持SIGKILL/SIGTERM/SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGSYS/SIGINT/SIGHUP/SIGPIPE。未知不能推0。
- reaped：必须在exit后，官方退出回调已确认且任务资源已全部释放。done在exit时完成，waitForExit只在reaped完成。

## Node契约与验证
spawn同步返回stdin:null、stdout/stderr Readable、control Duplex、done、terminate、waitForExit。write callback在对应全部ACK后完成；读取额度约束每流64KiB未消费缓冲。dispose请求全部停止并等待reaped；断连/协议失败拒绝未完成done和waitForExit，不能把销毁socket当进程已退出。

测试：`node --test harmony/tests/runtime-lifecycle/subprocess.test.mjs`；WSL可设`DSH_TEST_UNIX=1`使用Linux抽象Unix socket（不落盘）。10组实际provider及Node流/协议测试通过，包含分片、70KB写ACK、64KiB读credit、迟到spawn取消、并发ID、env删除、spawn失败、断连、旧代/过量data/早exit/未知signal/超帧/错ACK拒绝和dispose等待。D盘DrvFS路径socket listen实测ENOTSUP，改用抽象Unix socket验证，不据此推鸿蒙异常。

本测试的父端为协议夹具，尚未与Harmony broker/真实PTC整合；未启用bootstrap或配置，不能称本机完整执行已完成。
