Not verified on a physical device.

# Workshop v1 wire contract (7110 / 7150)

The [Chinese contract](workshop-api.md) includes complete JSON examples. Server timestamps are UTC ISO-8601. User-Api-Key is accepted only for the current request, never returned or persisted. Admin endpoints require X-Admin-Key.

## Public routes

GET `/api/workshop/v1/capabilities` returns schema=1, features:{uploads,companion}, kinds:[pet,companion], the fixed license choices, forumOrigin, maxMocVersion=6 and limits:{archiveBytes:20971520,expandedBytes:67108864,companionMemberBytes:16777216,companionEntries:1000,petEntries:256}.

GET/HEAD `/market/workshop.json` returns schema=1, generatedAt, features, entries and withdrawn. An entry has kind,id,version,minApp,title:{zh,en},author,license,source,url,sha256,size,blockedVersions. A withdrawal has kind,id,version,reason,at. `/market/companions.json` has the same shape with companion entries/withdrawals only; disabling companion returns503 for this projection and its downloads. The main catalog continues to return all withdrawal kinds. ETags are supported. Clients must revalidate current authority before installation/update, not use a stale catalog to bypass withdrawal or a switch.

GET/HEAD `/market/workshop/<kind>/<id>/<version>/<sha>.zip` authorizes current approved bytes, never a draft/rejected blob. It supports Range and If-Range without a direct-bucket redirect. Known SHA alone grants no access.

## Metadata and submission records

Creation metadata has kind,id,version,minApp,title:{zh,en},author,license,source,sha256,size,rightsConfirmed:true. Id consists of lowercase letters/digits separated by single hyphens, at most40 characters. Versions use the existing SemVer syntax without build metadata and cannot contain line breaks. Each title is at most120 Unicode code points; author256; source2048, HTTPS without credentials or whitespace. License is one of CC0-1.0, CC-BY-4.0, CC-BY-SA-4.0, MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause or LicenseRef-Author-Permission.

Pet pack.id/author/license/source must match. Companion character.json requires schema=1,name,model,author/license/source. The model is an existing relative model3.json beneath character/. The model's original name is permitted. Default export strips user names/persona; explicit export selection is an App decision. Runtime and index.json are not accepted; the installer rebuilds the index.

Success responses for a submission use `{submission}`. Each record has submissionId (32 lowercase hexadecimal characters), owner:{forumOrigin,forumUserId,username}, metadata, status, createdAt and updatedAt. Status is draft,pending,approved,rejected or withdrawn. Pending adds submittedAt and validation:{validator,files,expandedBytes,sheets? or mocVersions?}. Approved/rejected adds review:{at,decision,reason}. Withdrawn adds withdrawal:{at,reason}. Absent optional fields are omitted.

All following paths use prefix `/api/workshop/v1`:

| Request | Body | Success |
| --- | --- | --- |
| POST /submissions | requestId plus metadata; requestId is16..128 ASCII letters/digits/underscore/hyphen |201 initially,200 for the same idempotent metadata, {submission} |
| PUT /submissions/<id>/archive | application/zip bytes |200 {submission}, pending only after full validation; identical pending retry is idempotent |
| GET /submissions | ?limit=20&cursor=<id>&status=pending |200 {submissions,nextCursor}; own records only, lexicographic id order, default20/max100, nextCursor is null or last id |
| GET /submissions/<id> | none |200 {submission}, owner only |
| POST /submissions/<id>/withdraw | reason,1..2000 code points |200 {submission}, idempotent, works while uploads are disabled |
| POST /reports | kind,id,version,reason |201 {reportId}; only previously published versions, no automatic takedown |
| GET /admin/submissions | same pagination/status query |200 {submissions,nextCursor}, all owners |
| GET/HEAD /admin/submissions/<id>/archive | none |200/206 private review ZIP, Range supported |
| POST /admin/submissions/<id>/review | decision:approve or reject,reason |200 {submission}; approval revalidates actual bytes then CAS-publishes |
| POST /admin/submissions/<id>/withdraw | reason |200 {submission}; terminates abandoned drafts/pending/rejected records or withdraws approvals, retaining audit/history |
| GET /admin/reports | ?limit=20&cursor=<reportId> |200 {reports,nextCursor}; report fields:reportId,kind,id,version,reason,reporter,createdAt |
| POST /admin/releases/withdraw | kind,id,version,reason |200 {withdrawn:{kind,id,version,reason,at}} |

User operations require an independently verified forum key. The outer UI must match forumOrigin and explicitly confirm credential transfer to this Worker. No implicit forum_auth access is provided. Admin routes cannot use a normal forum key.

## Errors

Every business error is `{error:"workshop_<code>"}` without underlying exceptions, forum bodies or keys. The codes below omit that common prefix.

| HTTP | Codes |
| --- | --- |
|400 |bad_metadata,bad_request,bad_request_id,bad_query,bad_reason,bad_decision |
|400 |archive_*,json_*,pack_*,sheet_*,png_*,inflate_*,zlib_*,pet_extra_file,companion_* (package validation) |
|401 |forum_auth_required,forum_auth_invalid,admin_auth_required |
|404 |not_found (absent, not owned or not publicly authorized) |
|405 |method_not_allowed, with Allow |
|409 |request_id_reused,state_conflict,submission_state,version_rewritten,owner_conflict,version_withdrawn |
|413 |body_too_large |
|415 |content_type |
|422 |size_mismatch,sha_mismatch |
|429 |rate_limited, with Retry-After |
|503 |upload_disabled,companion_disabled |
|503 |forum_unavailable,forum_configuration,admin_unavailable,storage_unavailable,state_invalid,capacity,moc_policy_unavailable |

A failed write acknowledgement does not prove the remote write failed. Retry creation with the same requestId, and GET the original submissionId to reconcile. CAS conflicts do not publish orphaned blobs. Pagination is a live view without a cross-request snapshot guarantee. The historical moc ceiling is not Core consistency, current installed runtime identity, renderer or device verification.
