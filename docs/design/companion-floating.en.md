# Floating companion: a second renderer in the existing pet window

> Not verified on a physical device. 2026-11-11. Base 1a2af92b7cfbd5958173f57949d26f2dd8e060e8.
> [中文](companion-floating.md). This is the joint contract for 7010 → 7020 → 7021 → 7030. The Dart part also depends on the workshop App chain's CompanionPackStore integrity and change notifications. Integrate the complete chain and owner wiring together.

## Conclusion and evidence limits

Pixels remain the default. An explicit companion selection keeps PetOverlay as the sole owner of the window, service, visibility, gestures, docking, bubbles, ask-one, daily hiding and screenshot hiding. PetView hosts one WebView. There is no second overlay service or menu; placeMenu is unchanged.

An application-context WebView, hardware-accelerated window and transparent WebGL are supported API building blocks, not proof of compatibility across Android 8–16 and all vendors. Non-Activity context lacks some Activity features; this stage does not use JS dialogs or autofill. A false isHardwareAccelerated enters the bounded recovery/fallback path.[A1–A3] Whether forced system hiding promptly reports visibility remains a device gate; unknown hiding cannot be advertised as guaranteed GL release.

The room can share a renderer with the float view: it pauses JS in the background but retains its WebView, Android requires each affected WebView to handle renderer exit, and the pinned webview_flutter_android 4.14.1 WebViewClientImpl does not override that callback. Returning true for the float instance cannot handle the room instance.[A4,A5] The room's WebView is now taken over by IslandPlatform.attach, with its acknowledgement checked, before it loads, and cleans up after itself on renderer exit and before a pack change; see "Room and UI integration" below. This has only run as Dart tests on a fake WebView platform. Host survival after a renderer failure in room → Home → float still needs device evidence and must not be described as verified.

## Selection, availability and errors

PetPrefs persists pet.overlay_renderer (pixel / companion) and pet.overlay_framing (one JSON record for zoom and y). Missing/unknown modes select pixel. Zoom must be finite in (0,4], y in [-1,1]. Defaults 0.9 and 0 are configurable engineering choices, not measured ideal framing.

PetOverlaySettingsSection gains two rows, both the SettingsSegmentTile that "When to show" uses. "Show in the floating window" has two segments: the pixel pet, or the companion from the room (her name when companionNameProvider has one). Availability uses the same application-support/companion directory and unavailableReason to check the fixed runtime aggregate hash, model entry points, references and moc header version. It never downloads automatically or claims Core/GPU execution. Missing/incomplete content disables the whole control, and the subtitle gives one of three reasons: no character pack (companion_runtime_missing), an incomplete pack or wrong runtime (the other integrity codes), or anything else (storage, channel, native, local server and unknown codes). An already selected mode can always be switched back to pixels. Once selected, the subtitle is, in order: loading, the reason, the fallback, the battery note. "Framing" appears only while the companion is selected; its two segments write the PetOverlayFraming presets: full body zoom=0.9, y=0 and half body zoom=1.8, y=0.5. Half body is derived from the stage projection (the model is 2 tall around 0; screen y = (model y − floatY) × floatZoom) and has not been tuned on a device. When native reports companionFallback, a "Retry" follows the subtitle and calls CompanionFloatController.retry(): the session runs _refresh again for the same selection, and the new page starts a new native failure cycle.

CompanionFloatSession fences late checks/pages with a selection generation and store revision. The default pixel path performs no pack lookup, socket creation or WebView allocation. Each selected page uses the existing random-token loopback CompanionServer. Dart calls configureCompanion(page, notice) on the existing channel, or page=null to stop. Acknowledgement means native acceptance, not a visible frame. Native adds companionRendering, companionFallback and companionProblem only when a companion endpoint is selected; the original pixel status map stays unchanged.

MissingPluginException during setup maps to companion_native_unavailable; platform, file and socket failures map to companion_channel_failed, companion_storage and companion_server_failed. Errors contain stable codes, never token-bearing URLs, paths or raw exception text. Native startup, hardware, protocol, context and renderer failures also use fixed codes.

Same-root CompanionPackStore instances share a queue, revisions and beforeChanges hooks. Mutations announce a revision and await readers before moving directories. The float hook invalidates old generations, then serially awaits native destruction acknowledgement and server cleanup. It must not await a store operation while the store queue is held. Failed closes retain cleanup ownership and block mutation. The provider retains a factory, not a failed Future: explicit reselection or leaving and reopening settings retries storage, while the active Session keeps its successful store. A stale page is closed without publishing its capability to native.

CompanionServer.close rejects new work, force-closes the socket and waits for tracked handlers. Handlers recheck closed after asynchronous asset/type/length reads, so an old request cannot reopen a replaced directory. Room readers need the same change contract.

## Stage protocol and resource ownership

mode=float selects the new path; room mode retains its path. Float never creates the room scene's 2D context and omits backgrounds, objects, room pointer/voice interactions, props, day/night timers and autonomous mood events. Stage, WebView and window are transparent.

FrameGate enforces at least 1000/30 milliseconds between submissions. Refresh cadence and scheduling may produce a lower actual rate; the ceiling is not a promise of stable 30fps. DPR=1, maxTexture=1024, maskSize=512 and antialias=0 are cost controls, not memory or energy measurements. Each submitted frame reads actual alpha into a reused RGBA buffer; only changed bounds cross the bridge.

Native → JS: petState(state, reduceMotion), freeze, thaw, dispose. JS → native: floatReady, floatBounds(width,height,bounds), floatError(code), floatResume. Right/bottom bounds are exclusive; null means transparent. Ready means the model was established, not that asynchronous shaders finished.

Dimming freezes rAF only after both ready and the first nonempty pixel bounds. Otherwise a dimmed cold start could freeze a blank shader frame until timeout. Cancelling dimming during load prevents that freeze. Screen-off, actual hiding, power-save and disposal release resources instead of retaining the frozen picture. reduceMotion updates with petState, stops queued motions, and does not reload the page or reset the failure budget.

Idempotent disposal first invalidates the stage, aborts its own fetches and stops rAF, then releases the model and attempts WEBGL_lose_context. A release exception cannot suppress the fixed native error. Load continuations check disposal after awaits: late bitmaps close without creating textures; late motion/physics/pose input cannot allocate model resources. Model release alone does not prove all app-created textures or Framework static shaders were freed. The pinned Framework 5-r.5 generateShaders returns void and starts separate asynchronous fetches without this page's AbortSignal. Global Framework disposal is therefore not a safe synchronous cancellation substitute. Context loss and native removal/destruction provide the final boundary.[A6–A8]

## State mapping

Only emotions/actions explicitly authored in character.json or the adapter opt into effects. Missing actions stay idle; room generic defaults do not establish model capability. Repeated delivery of the same state does not replay its action.

| Pet state | Authored emotion | Authored one-shot action |
|---|---|---|
| idle | calm | None |
| thinking | confused | tilt |
| working / juggling / sweeping / carrying | calm | nodSmall |
| attention | happy | nod |
| notification | worried | lookUp |
| error | sad | shake |
| sleeping | sleepy | yawn |
| waking | calm | stretch |

## Geometry and touch in one window

The internal viewport stays fixed and is measured EXACTLY; the native window crops to actual nonzero-alpha pixels. GL bottom-left coordinates become top-left coordinates, then floor/ceil expands buffer bounds to view pixels. Touch outside the rectangle reaches the underlying app. Transparent holes inside it remain part of this window; this is not per-pixel touch-through.

For window position P, old bounds origin B and new origin B', P'=P+B'-B preserves the internal viewport origin P-B. dragStart/dropAt move by the same delta; dragging still uses the existing safe-area clamp. fullReach describes the fixed viewport relative to the crop so docking/menu/bubble code consumes the existing PetFrames contract. This identity does not establish all screen, density or vendor behavior.

Before the first real bounds the window has alpha=0 and NOT_TOUCHABLE, avoiding an invisible full-viewport touch surface. First nonempty bounds restore input. A later transparent frame uses a minimal alpha=0, non-touchable window while rendering continues. Fifteen seconds without any nonempty bounds is an engineering startup timeout.

PetView intercepts gestures; the child cannot focus or redefine tap, long-press and drag. showMenu is reused and placeMenu is unchanged. Initial viewport height is four times the selected pixel-body height, capped at 640 view pixels and the safe height minus both dock margins; width is 0.75 of height, capped by the safe width minus both margins. Patch 7021 corrects the previous inset-only cap: a viewport filling the safe height was still positioned one margin below its top by EdgeSnap, placing its bottom outside that area. The new cap keeps the fullReach inside the existing dock area. If the reported area cannot fit even one pixel between both margins, no companion WebView is created until the area becomes usable; the pixel path remains and no fault retry is consumed. Framing remains configurable; small displays, rotation and vendor behavior still require device testing.

## Visibility and failure lifecycle

Rendering requires selection, no fallback, SHOWN policy, an interactive screen, reported system visibility, no capture and no power-save. Known hiding, daily hiding, pause, screen-off, capture and power-save destroy the renderer; restoration creates a new one. WebView.onPause does not guarantee JS suspension, and process-wide pauseTimers is not used.[A1]

The failure budget belongs to the selected page capability, not a window creation. The first current-generation context/renderer/load failure recreates once; a second returns to pixels and shows one notice. Normal hide/resume does not reset the budget, and stale callbacks cannot consume it. Explicit deselection or a new pack/framing capability starts a new cycle. A failed renderer's WebView is never reused.[A4]

No improvement in background survival is promised. The existing window and service ownership remain in place.

## Room and UI integration

1. CompanionStage (app/lib/ui/companion/companion_stage.dart) reads the Android WebView id with WebViewGuard.identifierOf after setting the navigation delegate and before the first load, calls IslandPlatform.attach directly and checks its boolean acknowledgement. On false it fails with guard, and neither loads nor shows the WebView. Completion of the void WebViewGuard.attach wrapper is not proof of success, so it is not used. No plugin upgrade is required. The guard is required on Android only: attach is always false elsewhere, while those controllers also expose webViewIdentifier, so requiring it everywhere would keep the room from ever opening there.
2. The stage listens for IslandRendererGone on IslandPlatform.events. All WebViews share one renderer, so a report for any instance counts, but only once this instance is guarded, and it consumes no float retries. _retire does the cleanup: it bumps the generation, cancels the timeout, clears the controller's ready state and WebView, removes WebViewWidget, awaits CompanionServer.close and then reports the failure. An old start checks the generation after each stage of awaits; JS messages and load errors from the old page are dropped by generation. The old id is destroyed after the frame that removes its widget, without waiting for it.
3. The stage registers store.beforeChanges at the top of _start, before CompanionServer starts; the hook is _retire and never enters the store queue. Registering before the server leaves no window with a server up and no hook; a start overtaken by a pack change finds its generation stale once the server is up, closes it and gives up. dispose does not remove the hook at once but after the server has closed: CompanionPage._removePack switches to setup first (which unmounts the stage) and then calls remove, so removing the hook immediately would let the directory change before the server closed. The hook does not wait for destroy: no frame comes while the app is not visible, and waiting for one inside the store queue would stall it. Closing the server satisfies the reader contract, because the WebView reads the pack only through it.
4. A retired stage never loads again. CompanionPage shows its failed screen, the stage leaves the tree, and returning to the stage phase builds a fresh instance. Besides the existing import, the failed screen offers "Retry" (_retryStage) while the character pack is still installed. Renderer exit and pack change are not shown to the person as reasons: the screen uses the body without a reason and the reason goes to the debug log only; other reasons are shown as before. The page ignores a stage's failure callback outside the stage phase, so a failure reported by the hook while the pack is being removed does not turn the setup screen into the failed one. _removePack catches companion_readers_busy and other failures: the pack stays and the setup screen says so.
5. When another store for the same root changes the pack while the room is open, the room shows the failed screen and needs a retry or re-entry; the page does not rebuild itself on a revision. Background pause or assumed non-overlap cannot replace each affected WebView's guard; foreground transitions are asynchronous.
6. Run the project formatter, analyzer, full CI and affected goldens. Regenerate, never hand-edit, generated artifacts. If the stage corpus pin changes, use the existing tool and review its result; Core-free mocks are not a corpus run.

## Simulation checklist and settlement evidence

Executed Node checks cover timing/alpha/mapping and actual stage.js control flow in an isolated VM: float/room, initial freezing, dynamic reduceMotion, cancellation, late bitmap/motion continuations, release exceptions and context loss. Core, GL, fetch and native window boundaries are replaced. Passing them does not prove actual rendering. JVM and Dart tests are written but not run in this sandbox; deliverable evidence records exact counts and patch hashes.

The owner runs policy/geometry JVM, preference/channel/session/store/server/widget Dart tests and existing regressions. Use barriers for late integrity results, native acknowledgement, failed cleanup during pack change and factory retry; do not rely on probabilistic tapping. Include process restart, rotation, all existing menu/bubble/ask-one behavior and default pixel behavior.

Record build SHA, API, vendor/GPU, WebView provider/version, actual window type, density and refresh rate. Cover available Android 8/10/12/14/16 devices and disclose omissions. Check hardware acceleration, transparency, rectangular touch-through, small screens/large fonts/rotation, screen-off, power-save, daily hiding, screenshots and forced system overlay hiding. Test room→Home→float and coexistence with web/chart views during renderer failure: host survival, at most one first recovery, and one fallback notice on the second failure of the same selection. None of these device steps has been executed here.

Measure both host and renderer PSS during loading, steady state and after disposal, not just Dart heap. A texture estimate starts at 4×width×height, then adds mips, masks/FBOs, readback and Core; it is not a measured upper bound. For energy, compare pixel/float in paired 30-minute runs on the same device, brightness, network and temperature with a fixed model; use at least three pairs and measure idle/actions separately, including frame rate, temperature and battery/energy statistics. Do not publish savings or resident-memory numbers without measurements.

If devices disprove the direct transparent WebView path, retain pixels and let the owner choose alternatives. WebView.draw on software Canvas is not a reliable WebGL bitmap fallback under Chromium's documented restrictions.[A9] VirtualDisplay/SurfaceTexture or a native SDK need separate measurement/licensing work.

## Primary sources

Accessed 2026-11-11. API contracts and pinned source do not establish all-device support.

- [A1] https://developer.android.com/reference/android/webkit/WebView
- [A2] https://developer.android.com/reference/android/view/WindowManager.LayoutParams
- [A3] https://developer.android.com/develop/ui/views/graphics/hardware-accel
- [A4] https://developer.android.com/reference/android/webkit/WebViewClient#onRenderProcessGone(android.webkit.WebView,%20android.webkit.RenderProcessGoneDetail)
- [A5] https://github.com/flutter/packages/blob/9854cd5607da4001f2dd3cbdcd6903202d28958c/packages/webview_flutter/webview_flutter_android/android/src/main/java/io/flutter/plugins/webviewflutter/WebViewClientProxyApi.java
- [A6] https://github.com/Live2D/CubismWebFramework/blob/198a3769c26ca3d7b600e932590433badd392edd/src/rendering/cubismshader_webgl.ts
- [A7] https://docs.live2d.com/en/cubism-sdk-manual/use-framework-web/
- [A8] https://registry.khronos.org/webgl/extensions/WEBGL_lose_context/
- [A9] https://chromium.googlesource.com/chromium/src/+/HEAD/android_webview/docs/software_draw_deprecated.md
