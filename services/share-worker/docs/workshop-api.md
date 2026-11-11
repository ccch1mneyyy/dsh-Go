未真机验证。

# 创意工坊 v1 数据合同（7110 / 7150）

时间戳均由服务器生成的 UTC ISO-8601；投稿者键 `User-Api-Key` 仅随本次请求发送，不出现在响应或持久记录。管理员沿用 `X-Admin-Key`。

## 公共查询

`GET /api/workshop/v1/capabilities`：

```json
{"schema":1,"features":{"uploads":true,"companion":true},"kinds":["pet","companion"],"licenses":["CC0-1.0","CC-BY-4.0","CC-BY-SA-4.0","MIT","Apache-2.0","BSD-2-Clause","BSD-3-Clause","LicenseRef-Author-Permission"],"forumOrigin":"https://forum.dshtui.com","maxMocVersion":6,"limits":{"archiveBytes":20971520,"expandedBytes":67108864,"companionMemberBytes":16777216,"companionEntries":1000,"petEntries":256}}
```

`GET|HEAD /market/workshop.json`：

```json
{"schema":1,"generatedAt":"2026-11-11T00:00:00.000Z","features":{"uploads":true,"companion":true},"entries":[{"kind":"pet","id":"sample","version":"1.0.0","minApp":"1.0.13","title":{"zh":"示例","en":"Sample"},"author":"作者","license":"CC0-1.0","source":"https://example.org/sample","url":"/market/workshop/pet/sample/1.0.0/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1234,"blockedVersions":[]}],"withdrawn":[{"kind":"pet","id":"old-sample","version":"1.0.0","reason":"作者撤回","at":"2026-11-11T00:00:00.000Z"}]}
```

`/market/companions.json` 是同一状态的 companion 过滤投影，字段仍为 `entries`，没有独立发布存储。companion 关闭时投影及其下载返回503；主目录仍能浏览pet，保留所有种类的withdrawn以便本地处理已安装撤回。支持条件ETag；安装/更新前必须向服务器重新验证目录，不使用失效缓存绕过关闭/撤回。

`GET|HEAD /market/workshop/<kind>/<id>/<version>/<sha>.zip` 必须匹配当前公开条目、不可变绑定、未撤回；支持 Range / If-Range。待审/拒绝包即使SHA已知也不可从公共接口下载，不跳转裸桶。

## metadata 与投稿记录

```json
{"kind":"pet","id":"sample","version":"1.0.0","minApp":"1.0.13","title":{"zh":"示例","en":"Sample"},"author":"作者","license":"CC0-1.0","source":"https://example.org/sample","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1234,"rightsConfirmed":true}
```

id为小写字母/数字与单个连字符分隔，最多40字符；版本用既有validVersion（无build metadata）。source必须HTTPS且无用户密码；中英文title各最多120码点、author最多256。pet包内id/author/license/source必须一致。companion的character.json必须有schema=1、name、model、author/license/source；name可为模型原名，model为character内相对model3.json；拒runtime与index.json（安装器重建后者）。

所有投稿成功响应为 `{submission:记录}`。记录形状：

```json
{"submissionId":"0123456789abcdef0123456789abcdef","owner":{"forumOrigin":"https://forum.dshtui.com","forumUserId":42,"username":"sample"},"metadata":{},"status":"draft","createdAt":"2026-11-11T00:00:00.000Z","updatedAt":"2026-11-11T00:00:00.000Z"}
```

metadata是上面的完整对象。status枚举draft/pending/approved/rejected/withdrawn。pending增加submittedAt与validation（validator,files,expandedBytes,sheets?或mocVersions?）；approved/rejected增加review:{at,decision,reason}；withdrawn增加withdrawal:{at,reason}。可选键不存在时省略。

| 请求（前缀/api/workshop/v1） | 请求体 | 成功 |
| --- | --- | --- |
| POST /submissions | {requestId,...metadata}；requestId为16..128位ASCII字母数字_- | 首次201，同requestId且metadata一致重试200，{submission} |
| PUT /submissions/<id>/archive | application/zip 原始ZIP | 200 {submission}；验证后pending；pending相同字节重试可200 |
| GET /submissions?limit=20&cursor=<id>&status=pending | 无 | 200 {submissions:[...],nextCursor:null或id}，仅本人；limit默认20最大100，id字典序 |
| GET /submissions/<id> | 无 | 200 {submission}，仅本人 |
| POST /submissions/<id>/withdraw | {reason:"1..2000码点"} | 200 {submission}；上传关闭仍允许撤回；已撤回幂等 |
| POST /reports | {kind,id,version,reason:"1..2000码点"} | 201 {reportId}，只举报已发布版本，不自动下架 |
| GET /admin/submissions | 同列表查询参数 | 200 {submissions,nextCursor}，所有作者 |
| GET或HEAD /admin/submissions/<id>/archive | 无 | 200/206 私有审核ZIP，Range可用 |
| POST /admin/submissions/<id>/withdraw | {reason:"1..2000码点"} | 200 {submission}，管理员可撤回废弃draft/pending/rejected以及已批准版本，保留审计与历史 |
| POST /admin/submissions/<id>/review | {decision:"approve"或"reject",reason:"1..2000码点"} | 200 {submission}；approve重验字节后CAS |
| GET /admin/reports | ?limit=20&cursor=<reportId> | 200 {reports:[{reportId,kind,id,version,reason,reporter,createdAt}],nextCursor} |
| POST /admin/releases/withdraw | {kind,id,version,reason:"1..2000码点"} | 200 {withdrawn:{kind,id,version,reason,at}} |

公开查询无需身份。创建、上传、本人列表/查看、撤回、举报都需论坛User API key。外层UI先核对forumOrigin并明确确认将凭据交给这个Worker；本层不隐式授权。

## 失败

失败固定JSON `{error:"workshop_<code>"}`，不含底层异常、论坛正文或凭据。论坛响应过大/格式不符/身份不明失败关闭。

| HTTP | code（统一加workshop_前缀） | 含义 |
| --- | --- | --- |
| 400 | bad_metadata / bad_request / bad_request_id / bad_query / bad_reason / bad_decision | 输入无效 |
| 400 | archive_* / json_* / pack_* / sheet_* / png_* / inflate_* / zlib_* / pet_extra_file / companion_* | 包验证失败，未进入待审 |
| 401 | forum_auth_required / forum_auth_invalid / admin_auth_required | 身份失败 |
| 404 | not_found | 无记录/非本人/非公开资源 |
| 405 | method_not_allowed | 方法不支持 |
| 409 | request_id_reused / state_conflict / submission_state / version_rewritten / owner_conflict / version_withdrawn | 并发或不可变冲突，GET重核 |
| 413 | body_too_large | 大小超限 |
| 415 | content_type | 需要application/json或application/zip |
| 422 | size_mismatch / sha_mismatch | 字节与metadata不同 |
| 429 | rate_limited | 限流，带Retry-After |
| 503 | upload_disabled / companion_disabled | 紧急开关关闭 |
| 503 | forum_unavailable / forum_configuration / admin_unavailable / storage_unavailable / state_invalid / capacity / moc_policy_unavailable | 服务或维护错误 |

提交超时不能证明未写入；使用同requestId重试创建、GET原submissionId核状态。CAS冲突409，孤立私有blob不会成为已批准。分页为实时视图，不承诺并发写时快照一致性。moc上限6来自基底历史实测，不等于本次Core一致性检查或GPU/真机验证。
