Not validated on a physical device.

# App workshop data layer and export

[中文](workshop-app.md). This candidate follows TASK and ADDENDUM-02. The [Worker v1 contract](../../services/share-worker/docs/workshop-api.md) is authoritative. Dart/Flutter tests have not run; this document is an implementation contract, not a merge approval.

Catalog refresh preserves all known withdrawn and blockedVersions records. A later response cannot make a known blocked release installable again; records may move between an entry and the withdrawn ledger. Unknown kinds validate common metadata and may have larger archives or future license identifiers. They remain unsupported and cannot be submitted, downloaded or passed to current installers.

downloadDirectory must be an app-private directory dedicated to this module. Repositories for the same normalized directory share a serial queue so a replacement provider cannot prune a ZIP still in use by an older installation. The cache keeps one resumable resource slot: selecting another SHA prunes only older `<sha>.zip` and `<sha>.zip.part` files, without recursively deleting unrelated directories. Selecting another resource forfeits the previous incomplete resume. Cleanup failures surface as storage errors. Requests arriving after an openUrl timeout are aborted; header/body setup failures also abort an acquired request.

Clients using the same normalized cacheFile share the catalog transaction queue and latest known withdrawal set. The queue covers the request, parsing and disk write, so an old client cannot replace a newer client's accepted history with its private stale copy. Changing Worker origins rechecks the disk cache binding. When companion is disabled its public rows disappear; installation and installed-state queries therefore check the explicit feature first and report workshop_companion_disabled while retaining the installed withdrawal flag separately.

A first cache read that fails with a storage error can retry on the next serial catalog transaction while there is no healthy memory copy. A replacement client using the same normalized path can retry too, and a successful read clears the old cache_storage issue. Once a newer catalog is accepted from the network, a failed save does not permit old disk bytes to replace that memory copy or its known withdrawals. Offline recovery only supplies browsing marked stale; requireFresh installation checks still fail offline. The 7152 delta defines three regressions for these cases; Dart/Flutter tests have not run.

## Entry points and catalogs

`WorkshopClient(origin, cacheFile, http?)` requires an explicit HTTPS Worker origin and an app-private cache. It has no hidden production deployment. `WorkshopRepository(client, packages, downloadDirectory, appVersion, freeBytes?)` coordinates downloads and installation. `LocalWorkshopPackages(pets, companion)` delegates to the existing PetLibrary and CompanionPackStore installers.

`catalog(requireFresh: false)` attempts a refresh and may return a stale cached catalog with its refreshError. Installation uses requireFresh before downloading and again before installing; neither check falls back offline. cacheIssue reports damaged or unwritable cache state, including when no usable cached catalog exists. The cache contains public catalog data, ETag, origin and fetch time, never account credentials or private submissions. A 304 requires a valid cache for the same origin. Entries validate kind, version, minApp, the exact content-addressed URL, SHA and size. Unknown kinds remain visible as unsupported and never reach a pet installer.

Both server switches default on. A disabled service produces explicit upload_disabled or companion_disabled errors. Existing installations are not automatically removed during network failures or shutdowns. Clients cannot anticipate a withdrawal occurring after the final network round trip or recover copies already downloaded; this does not permit stale catalogs to authorize new installations.

Worker versions allow 80-character SemVer numeric identifiers beyond int64. Comparisons therefore use digit-string length and lexical order without precision loss. Release versions exclude build metadata; an installed Android app version may have its `+…` suffix removed for minApp comparison.

## Downloads and installations

The repository reuses ApkDownloader for ranges, resume, retries, cancellation and SHA-256. Its transport wrapper accepts only the selected URL, forbids redirects, checks Content-Range and bounds streamed data by catalog size even without Content-Length. Space preflight reserves the ZIP, a 64 MiB staging tree, copied companion runtime and 4 MiB overhead. The existing Android update info reports cacheDir free space; callers may inject a probe for the actual destination filesystem. Unknown space is not evidence of sufficient space. ENOSPC and EDQUOT received directly by this layer map to no_space. The existing downloader collapses write failures into storage and loses errno, so this layer probes space again after that failure. Confirmed insufficient space maps to no_space; an unavailable probe can only produce an explicit storage error, not a claim that the disk is known to be full.

`.workshop-source.json` records only kind, id, version, SHA and Worker origin. It is written into staging and moves atomically with the resource directory. A manual import carries no receipt, so it cannot masquerade as the old workshop version. Network identity is `(kind,id)`; pet folder naming still uses userPetIdFor. Colliding pet folder mappings and replacement of a different companion in the single companion slot require explicit replaceExisting.

The installer checks the current receipt inside its own queue before promotion. The same version cannot acquire a different SHA, and an older download cannot downgrade a newer installed version. Uninstall carries the observed receipt and refuses to remove a subsequently replaced package. states(catalog) keeps installed, updateAvailable, installedWithdrawn and unavailable separate for public entries. installedStates(catalog) retains every installation even when withdrawal removes its public entry, with an explicit withdrawn status and an uninstall target. Receipts from another Worker are not mistaken for entries of the current catalog. Removing an asset does not touch memory, conversations, voice or forum identity.

Workshop companions contain character data only. A matching pinned runtime must already be installed; otherwise installation returns runtime_missing. This layer does not download runtime automatically. Workshop character imports use the existing installer and the new integrity gate; existing local import calls remain available.

## Companion integrity and lifecycle

`Future<String?> unavailableReason()` returns null after the file-integrity gate. Reasons include companion_runtime_missing, companion_runtime_incomplete, companion_runtime_mismatch, companion_missing_index, companion_bad_index, companion_missing_reference, companion_bad_moc, companion_moc_version, companion_unsafe_path and companion_storage. It verifies the full runtime digest, core/framework/shaders, indexed files, model3 moc/texture/physics/pose/expression/motion references, strict JSON and moc format enum up to 6. It does not execute Core or prove Moc consistency, device GPU support or rendering quality.

Stores with the same root share a queue, revision and revisions stream. `beforeChanges(stopReaders)` registers an asynchronous barrier and returns an unregister function. A mutation publishes a starting revision, waits for every barrier, then changes directories. Failure produces companion_readers_busy without moving live. Success and failure both publish a settlement revision. A barrier must not await another queued store operation, which would wait on the queue it currently holds.

The floating integration subscribes before checking availability and discards results if revision changes. Its barrier first awaits native `configure(float: null)` and WebView destruction, then server.close. Revision notifications trigger fresh asynchronous checks and reconstruction; a separate check generation discards late completions. Interrupted pack.previous promotion is recovered by the next operation. Removal first renames live to trash, preventing partial deletion and resurrection from backups.

## Export and privacy

`PetLibrary.exportZip(id, destination, publicId?, author?, license?, source?)` reconstructs a schema-1 manifest from supported fields and includes only referenced PNGs. Unknown keys, unrelated files and receipts are omitted. The same PetPackValidator checks the result. Public attribution overrides align the exported manifest with submission metadata.

`CompanionPackStore.exportZip(destination, name?, persona?, author?, license?, source?)` selects the model and referenced resources from pack/character, rebuilding Cubism and adaptation data. It omits runtime, index, receipts, unknown configuration, notes, UserData, motion events, all audio and Sound references. Explicitly named LICENSE/COPYING/NOTICE text files are retained. The installer rebuilds index. Adaptation parameters, emotions, actions, zones, tail, pose and framing remain data. Filesystem links are rejected.

The default name is the neutral `Companion`; persona is absent. Name/persona are included only when the caller explicitly supplies them for this export. No personal preferences are read. Export does not inspect memory, chats, voice-sample or credential stores outside character. It cannot prove the semantic privacy of arbitrary author-created media; the guarantee is that these personal data sources and unknown JSON fields are not copied. The submission UI should show the final member list.

preparePet and prepareCompanion take WorkshopPublication and return WorkshopPreparedUpload with the file, hashed metadata and actual ZIP member names. Existing destination files are not overwritten.

On the owning App isolate, exports resolve the target parent's real path and share a destination queue across pet and companion stores. The queue covers compute and commitment. After writing private staging, commitment checks again that the target is absent; conflicts return workshop_export_exists. This protects concurrent use of this App export API and does not claim that ordinary rename is a cross-process filesystem no-replace primitive.

Every exported companion PNG reuses the complete pngIntact gate: 8 MiB encoded, 4096 per side, 16 MiB decoded RGBA, CRC/IDAT and pixel decoding. Invalid or oversized textures fail preparation with a stable error without tightening ordinary local import or weakening the Worker. Exported JSON members remain limited to 1 MiB and empty license/notice files are omitted. When character.model is absent, export follows the stage's first model in index order rather than changing characters because another path is shallower.

## Author APIs and credentials

WorkshopCredential.forConsentedWorker represents confirmation already obtained by the UI; it does not obtain consent itself. It binds a forum key to the disclosed Worker and forum origins. The key is sent only with the current API request, never serialized into cache, receipts, bodies or errors. capabilities must report the matching forum origin. Real transport forbids redirects and never forwards credentials to a raw download bucket or arbitrary URL.

Author methods are createSubmission, upload, submit, submission, submissions, withdraw and report. create/submit require a separate explicit rightsConfirmed argument; having catalog metadata is not a declaration of sharing rights. Callers persist the non-secret requestId before starting. newRequestId returns 32 random hexadecimal characters. Repeating the same ID has server idempotence semantics; submit does not upload again once the returned state is beyond draft.

Upload holds a bounded, hashed byte snapshot and sends those exact bytes. Submission state and review/withdrawal reasons survive parsing. Pagination is a live server view, not a revision snapshot. Write timeouts, lost connections and malformed successful responses mark resultUnknown; reconcile by submissionId or repeat the same requestId before claiming nothing was submitted. Withdraw and report remain available while new submissions are paused. The app layer stores no administrator key and provides no operations moderation UI.

The local User API Key format gate matches the Worker at 1–512 printable ASCII characters. The author's list can contain 100 valid multibyte records, so that endpoint alone uses an 8 MiB bounded response, matching the Worker state object cap. Other ordinary JSON requests retain their 1 MiB bound; maximum pages do not introduce unbounded reads.

## Required local integration and validation

Local work includes browse/submission/moderation pages, localized stable error messages, concrete replacement confirmation, official forum identity retrieval and first-use key disclosure, persistence of request/submission IDs, pet refresh and companion lifecycle wiring after changes. This does not authorize changes to the task's excluded files.

Candidate tests cover catalog/cache/minApp/unknown kinds/withdrawal, resume/hash/cancel/space, receipts and stale removal, export round trips, privacy sentinels, reader barriers and interrupted promotion. Dart and Flutter are absent in this sandbox; neither analysis nor tests have run. Local execution and independent review remain required. Device testing must cover low space, network/process interruptions, floating view destruction/recreation during replacement, missing or damaged runtime, vendor WebView/GPU behavior and the export/share flow.

With DSH_WORKSHOP_CONTRACT_OUT explicitly set to an empty directory, workshop_export_contract_test.dart saves the actual App-exported pet/companion ZIPs and metadata for the frozen Worker validator. Without it, the App round-trip test still runs but leaves no persistent files. Its synthetic moc is a format fixture, not a Core model. Only local Flutter execution together with Worker acceptance of those same bytes proves the cross-runtime round trip; Node-generated ZIPs do not establish that evidence.

## Extraction storage failures (7153)

Companion extraction retains the original storage-error type, errno and stack before the existing no_space/storage mapping. Closing output after a failed write, and closing input after a failed transaction, cannot hide the primary error. Output close failure after a successful write remains storage; non-storage extraction errors remain notAPack. Production still extracts in a compute isolate. Only the testing constructor replaces one output-file-stream boundary and runs the same installation transaction in the current isolate.

Four new test definitions use real ArchiveFile extraction, temporary ZIPs/files and a real FileHandle delegate. They cover a partial write, errno 28/5, a primary failure plus failed close, close-only failure and an archive error. Every case compares the old package/receipt byte-for-byte, checks staging cleanup and reads the old identity through a new store. Failures are injected, not measured disk exhaustion. Dart/Flutter have not run. Dependency control flow was checked at the official archive v4.6.0 tag commit `3852d7e402a2a796d3f2af00ac3c28f129c0bb78`; the published tarball was not downloaded and compared with the lockfile digest. The local run must use the locked package.
