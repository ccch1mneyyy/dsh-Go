未真机验证。

# 创意工坊 Worker：投稿、审核与公开下载

这份实现对应 workshop1 的 7110。权威入口是 `/market/workshop.json`，新增 `/market/companions.json` 为其过滤投影；既有 `/market/pets.json`、适配表和定时同步保留原发布路径。分开权威对象的原因是原 Cron 会从维护者的上游目录同步宠物：把用户投稿直接写到旧对象会被后一次同步覆盖。

协议的精确请求/响应、错误码和分页见 [workshop-api.md](../../services/share-worker/docs/workshop-api.md)，公开目录 schema 见 [workshop.schema.json](../../market/schema/workshop.schema.json)。App 应按 kind 分派安装器，忽略未知 kind；以后追加 wallpaper、launch、theme、card 的能力与验证器不要求改写旧 pet/companion 行。

## 状态和发布

私有 `BUCKET` 的 `workshop/state-v1.json` 是唯一权威对象。一次 R2 条件 PUT 原子提交投稿状态、公开当前版本、永久版本绑定、作者绑定、撤回记录、举报和审计。更新用读取到的 ETag 做 If-Match；首写用 If-None-Match `*`。CAS 输家返回409，不覆盖胜者。存储异常返回503，不能从异常推断远端未写；客户端用同requestId重试创建，再GET原submissionId核实。

ZIP先完整验证，再以 `workshop/blobs/<sha>.zip` 创建一次；R2还核对原生SHA-256。blob在审核通过后仍留在私有桶。孤立blob、待审、拒绝包都没有公开可访问的裸桶路径。blob已存在不是审批凭据；批准时重新读实际字节、核size/SHA，再执行当前验证器，最后提交权威状态。

状态机是 draft → pending → approved/rejected；作者可从这些状态撤回，withdrawn不能恢复。新id在首次批准时绑定论坛origin+数值userId；draft不占有id。版本首次批准后绑定kind/id/version/SHA/size；升级、撤回、当前行消失均不删历史。原字节可重新批准为未撤回的旧版；相同版本不同字节、另一作者接管、恢复已撤回版本都被拒绝。批准另一版本会替换这个kind/id的当前公开行。撤回旧版本不隐藏当前新版，但其blockedVersions永久携带旧版本。举报不会自动下架；管理员先查证再撤回。

每次公开GET、HEAD、Range、条件请求都先读当前权威状态。下载必须精确匹配当前行和永久绑定；真实R2 GET/HEAD的checksum也须匹配。复用既有serveObject的Range/条件语义，并补If-Range检查。客户端下载响应为private/no-store，目录为no-cache/must-revalidate；ETag覆盖实际目录和开关投影。关闭companion后旧ETag、HEAD或Range均不能绕过503。主目录继续返回pet及全部撤回记录，companion投影和对应下载一起关闭。审核私有下载仍可用，便于处置存量问题。

7113按[RFC9110 §13.1.5](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.5)修正If-Range日期为精确匹配Last-Modified，仍将R2 uploaded按HTTP秒精度比较。强验证前提来自不可变内容对象及实际摘要检查；较早或较晚日期均忽略Range并返回完整200，不能使用If-Unmodified-Since的≤比较。强ETag精确匹配可206，弱ETag不能匹配，没有Range时忽略If-Range。小型回归覆盖这些分支，没有改变权威状态、发布、撤回或对象校验。

## 身份、开关和滥用限制

按ADDENDUM-02，`WORKSHOP_UPLOAD_ENABLED=1` 与 `WORKSHOP_COMPANION_ENABLED=1` 随配置交付，缺省也开启；设为0（或其他非1的显式值）分别返回稳定的workshop_upload_disabled或workshop_companion_disabled。上传关闭不阻止本人查询、撤回、举报和管理员拒绝/撤回。旧宠物市场不受这两个开关影响。

Worker只向配置的HTTPS论坛origin请求 `/session/current.json`，默认 `https://forum.dshtui.com`；拒绝带路径/凭据的配置，并以manual方式接收响应、拒绝所有非200状态而禁止跟随重定向。本地workerd证实redirect:error不受支持，不能照搬浏览器/Node的该选项。只传User-Api-Key，不转发客户端Cookie、Authorization、可变论坛URL或User-Api-Client-Id；后者在Discourse模型中可能修改key所属client。只信官方当前用户响应中的正整数id和用户名，拒绝错误状态、过大或无有效身份的响应。完整key不落R2/KV/日志，也不作持久指纹。用户名是显示快照；稳定身份是origin+userId。

现有论坛登录key有read/session_info所需范围，可以验证身份；这不自动授权把凭据发到另一个服务。App外层必须明确核对官方forumOrigin并确认凭据转交，数据层按单次调用显式接收，不读取或持久化forum_auth。长远可由论坛插件签发限定audience/操作/包SHA/nonce/短过期时间的投稿票据；本补丁没有伪造这种尚不存在的验证服务。管理员使用既有X-Admin-Key，审计actor为admin，不能据此归因到某一个管理员个人。

沿用现有限流绑定及KV计数，论坛校验前做每IP读限流，写入增加突发限制；论坛用户分别每小时5次新投稿、20次archive尝试、20次举报/撤回。archive失败尝试也先计数。KV跨colo是近似计数，既有计数器异常fail-open，不能称为强配额或全局DoS防护。所有鉴权/存储错误在此路由转换为固定码，不输出底层异常或论坛正文。

## 审计和容量

metadata强制中英文title、author、固定license列表、HTTPS source、rightsConfirmed=true，以及SHA和size。服务器createdAt记录确认时间；每次create/submit/approve/reject/withdraw/report和操作者、原因都与状态一起CAS提交。审计至少保留186天，覆盖六个日历月；只在后续写入时清理更老事件。永久版本绑定、作者归属、撤回和投稿元数据不自动清理。workshop前缀不能配置7d/30d生命周期。

权威对象上限8MiB，当前条目最多1000、永久绑定最多10000、撤回4000、投稿/举报各10000、审计20000；它们都是硬上限而非容量保证。每个未撤回投稿另预留24KiB、每个未撤回发布另预留12KiB，含最坏UTF-8撤回原因/审计字节及名额，避免普通投稿或举报填满后无法撤回已有内容。实际容量会较早触顶，返回workshop_capacity；不丢弃六个月内审计或历史来腾空间。管理员可通过admin/submissions/<id>/withdraw终止废弃draft/pending/rejected，释放预留但保留记录；不会让无人完成的draft永久占住预留。规模化前需由维护者设计带校验的历史归档/分片迁移，不能手删binding。当前没有声称能承载万级活跃投稿。

## 包验证与App的关系

pet复用App精确规则JSON、其Unicode15固定表和既有88项合成共享夹具（另有6项新专项测试）。构建生成数据，指纹覆盖验证源码、生成器、锁文件、规则和Unicode数据。ZIP在解压前逐个检查目录、路径、NFC后全casefold冲突、局部头、重叠区间、链接、压缩/加密标志；有界inflate检查实际EOF、尾随字节、CRC与声明长度。JSON严格UTF-8，无BOM、重复已解码key、孤立代理项、非有限数或过深嵌套。其中24项manifest夹具只补入投稿必需的固定授权元数据，几何/引用内容不变；不会把缺少市场元数据的本地包说成可直接投稿。schema、frame/scale整数、Float32几何、所有动画引用、atlas边界遵守当前App本地导入门槛。

PNG检查完整CRC和chunk顺序、合法色型/深度、PLTE/tRNS、连续IDAT、zlib EOF/Adler32、元数据解压预算、Adam7/普通scanline、filter0..4，并逐像素还原RGBA采样。它不是只读图片header。IDAT采用两遍扫描后定长拼接，不累积每chunk的对象；每行解码后释放工作区。校验ZIP/PNG时不保留完整状态快照，完成后再读最新状态和CAS。合法输入的接受域未靠缩弱校验扩大。

明确的较严子集：投稿ZIP压缩≤20MiB（App宠物本地≤64MiB），只收ZIP32；目录必须为空且完整CRC/EOF有效；pet仅一个根或单层目录pack.json及引用PNG，拒绝多余成员，元数据必须与投稿声明一致；不在服务端猜测或修补作品几何。App导出应生成这一干净子集。

companion只收character/数据白名单（json,moc3,png,jpg,jpeg,webp,wav,mp3,txt,md），拒runtime代码，拒index.json（安装器重建）；所有成员CRC/实际展开长度受限，JSON严格解析，所有model3的必需Moc/Textures及expression/motion/physics/pose/userdata/display文件引用必须在角色目录内实际存在。character.json的授权元数据必须一致，name/model必需；明确选择的persona/name属于App导出决策，服务器不读取本地偏好。moc3要求MOC3头、格式枚举1..6，未来/未知枚举拒绝。

7112把companion JSON改为逐成员完成严格解析和语义校验。ZIP目录在循环前已经完整校验，character/model的引用直接对该目录检查，不依赖被引用文件排在前面。单个JSON函数返回后，不把其完整对象加入跨成员Map；仅保留character通过标志、model数量和原有moc版本集合。所有JSON仍完整解析，包括未引用的附加数据；所有model3仍检查引用，包括未被character选中的模型；后续成员仍逐个核CRC、PNG和moc门。文件、字节、深度及引用接受规则没有收紧或放宽，构建时验证器源码指纹随本次修订更新。若一个无效包同时有多个问题，逐成员语义校验可能先报不同的现有400验证码；此类包仍拒绝。

该调整移除了随JSON成员累计保留的对象图，不是流式JSON解析或完整内存保证。单JSON仍会完整形成对象图；其节点复杂度、解析临时字符串、PNG完整scanline、zlib拼接瞬态和其他请求的缓冲都需要运行时测量。对象离开函数作用域也不保证GC立即归还内存。[Workers内存限制](https://developers.cloudflare.com/workers/platform/limits/#memory)是每个isolate 128MB，一个isolate可能同时承载多项请求，不能把64MiB归档展开门当作堆预算。

上限6来自基底 `tooling/companion/fixtures/live2d-core-sources-v1.json` 的2026-11-07历史实测：官方Core6.0.1、SHA8741…ef47、latestMocVersion6。此处没有重测Core，也没有验证实际安装runtime的聚合摘要。版本头通过不等于Core一致性或所有模型功能可渲染；批准者仍须用获准的固定Core做完整一致性/加载检查，并核对模型许可、内容和实际App效果。Worker不附带Core/runtime/模型/贴图。companion≤1000成员、单成员16MiB、展开64MiB；PNG沿用pet完整上限，其余数据格式不冒称已做音视频或Core完整解码。

## 本地证据与部署门槛

Node合成单测覆盖鉴权、投稿幂等、审核/拒绝、他人访问、版本重写、所有权、撤回/blockedVersions、报告、开关、Range/If-Range、真实GET checksum、CAS并发及固定错误；本地workerd对同一生产bundle运行44项App PNG语料、合法pet、deflate尾随/截断/输出上限。另有本地workerd/R2模拟绑定与合成论坛响应的全流程测试，实际结果见交付日志；这不是Cloudflare R2或Discourse联机验收。上限2048×2048、16bit RGBA的正常PNG（33,556,480字节scanline，4,194,304像素）在本地workerd验证成功；没有测量进程峰值，也没有穷举最大压缩包、元数据、并发的叠加。

标准build在给定快照中因site/share/apple-touch-icon.png缺失而中止。为运行Worker测试，SITE_BUILD指向单独临时fixture，只补合成1px图标；没有把它冒充站点素材或写回源站。整套旧测试仍有与快照资产、可执行位及工具环境相关的失败，交付README/日志列明。新增测试、typecheck和本地workerd结果与这些失败分别报告。

7112新增小型合规多JSON夹具，覆盖stored/deflate下不同成员顺序、未选中model3的全部引用类别，以及晚到的无效JSON、CRC、PNG和moc拒绝。它们验证逐成员重构的内容合同，不提供最大JSON堆、进程峰值或并发验收结果。

部署前本机必须完成：恢复既有站点资源/执行位；正常npm ci/build/typecheck/test与Wrangler dry-run；确认付费WorkerCPU预算和每isolate 128MB内存限制下的完整路由峰值/并发压力，不能从像素payload上限推导全进程内存保证；配置私有BUCKET无公开域名与workshop保留策略；设置ADMIN_KEY但不提交仓库；用测试论坛账户确认read/session_info与撤销key行为；人工审批测试样本；验证R2 CAS、checksum、Range/断网重试、关闭/撤回后旧请求；由App真机验证导入、已有runtime保留、导出回导和中文错误。补丁没有部署或向真实论坛外发。

## 一手依据

- Discourse [User API keys规范](https://meta.discourse.org/t/user-api-keys-specification/48536) 与 [UserApiKeyScope实现](https://github.com/discourse/discourse/blob/main/app/models/user_api_key_scope.rb)：身份请求范围和client header行为。
- Cloudflare [Request重定向语义](https://developers.cloudflare.com/workers/runtime-apis/request/)、[Workers node:zlib](https://developers.cloudflare.com/workers/runtime-apis/nodejs/zlib/) 与 [平台限制](https://developers.cloudflare.com/workers/platform/limits/)：需要nodejs_compat及相应兼容日期，内存/CPU另受平台限制；配置采用2026-10-01。
- Live2D [Cubism5.3兼容性](https://docs.live2d.com/en/cubism-sdk-manual/compatibility-with-cubism-5-3/) 与 [moc3一致性](https://docs.live2d.com/en/cubism-sdk-manual/moc3-consistency/)：文件版本、Core检查、renderer功能是不同层次。
