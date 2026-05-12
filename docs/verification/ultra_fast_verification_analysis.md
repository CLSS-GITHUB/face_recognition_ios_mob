# Ultra-Fast Verification — Analysis & Recommendations

**Status:** Proposal · awaiting approval · no source has been modified as a result of this document.
**Reference commit:** `ccc0a2c` (TTS init: fix concurrent-init race that defeated O-6 prewarm).
**Author:** session-driven performance audit, 2026-05-12.

---

## 0 · Scope

User ask: *"Verify Identity is taking too long — make it feel like iPhone Face Unlock."* This document:

1. Maps every stage of the verify pipeline with measured/estimated timings against the in-tree code (§2).
2. Distinguishes remaining bottlenecks from stages already at the floor (§3, §4).
3. Compares us to iOS Face ID honestly — the gap is **structural, not optimisation** (§5).
4. Proposes a prioritised hit-list with effort, risk, and expected wall-clock saving (§6).
5. Lists what NOT to optimise and why (§7).
6. Sets benchmark targets for each stage so "done" is measurable (§8).
7. Addresses security trade-offs (§9).

---

## 1 · What this session already shipped (relevant)

Before recommending more work, the baseline against which "ultra-fast" should be measured already includes:

| Commit | Optimisation | Stage affected |
|---|---|---|
| `8467452` | Phase B — Laplacian blur gate (rejects motion-blurred probes pre-extract) + dropped unused ML Kit `enableContours` (~3 ms/frame back) | Per-frame quality |
| `76490fb` | Phase D — decode + crop + eye-align + resize moved into the embedding isolate via `TransferableTypedData` (zero-copy) | UI thread (saved ~16 ms/frame on the verify loop) |
| `27cde8d` | XNNPACK delegate with CPU-golden validation gate (all 65/65 nodes delegated, single partition on the Samsung test device) | TFLite extract (~30 → ~20 ms) |
| `3455388` | O-5 speculative pre-extract during liveness + O-6 TTS prewarm | Match latency (~45 ms saved when speculation hits) + TTS first-utterance (~50 ms) |
| `ccc0a2c` | TTS init concurrent-race fix (cached future) | TTS prewarm reliability |

These changes are real. The work proposed below is on **top of** this baseline.

---

## 2 · Current verification timing analysis

### 2.1 Cold path: home → /verify → first preview frame

| # | Stage | File:line | Wall-clock |
|---|---|---|---|
| 1 | `context.push('/verify')` + fire-and-forget `verifyPrewarmProvider` | `home_screen.dart:84-87` | ~0 ms |
| 2 | Default Material route transition | `app/router.dart:63-66` | ~250-300 ms anim (overlapped with #3-#6) |
| 3 | `verificationControllerProvider.build()` — FSM, accelerometer subscribe, schedule `_warmTemplates` | `verification_controller.dart:207-240` | <1 ms sync |
| 4 | `_warmTemplates()` — AES-GCM decrypt every active user | `verification_controller.dart:291-307` | **30-120 ms** depending on N users |
| 5 | TTS prewarm (unawaited) | `verification_screen.dart:39-46` | non-blocking |
| 6 | `CameraPreviewWidget._bootstrap` — `availableCameras()` → **`CameraController.initialize()`** → `startImageStream` | `camera_preview_widget.dart:49-75` | **Cold: 250-700 ms** (camera2 driver open) |
| 7 | First `onImage` callback fires | `camera_preview_widget.dart:77` | ~33 ms after stage 6 |

**Cold-start ready latency: ~400-900 ms on Android, dominated by stage 6.** Stage 6 is **not currently prewarmed** — `verifyPrewarmProvider` warms `availableCameras`, the template bank, and the isolate, but the `CameraController` instance is owned by the widget and constructed on `initState`.

### 2.2 Warm-path per-frame loop

| Stage | File:line | Cost |
|---|---|---|
| Camera plugin `onImage` re-entry + per-frame `print` log | `camera_preview_widget.dart:77-82, 91-95` | ~0.05 ms (but see §3.1) |
| `CameraImageConverter.toInputImage` | `camera_image_converter.dart:20-48` | <0.3 ms |
| `_busy` gate + `Future.microtask` dispatch | `camera_preview_widget.dart:98-105` | ~0.1 ms |
| `FaceDetectionService.detect` (ML Kit fast mode, no contours) | `face_detection_service.dart:14-30` | **18-30 ms** on Pixel-6 class @ 640×480 |
| `_approximateBrightness` (stride-sampled luma) | `verification_controller.dart:391-394, 932-944` | ~0.2 ms |
| `MotionVarianceDetector.recordCentroid` (+ 1 `_Centroid` alloc) | `motion_variance_detector.dart:25-30` | <0.1 ms |
| `QualityAssessor.assess` (allocates `issues: <String>[]`) | `quality_assessor.dart:16-77` | <0.2 ms |
| **(liveness)** `_handleChallenge` | `verification_controller.dart:454-556` | <0.1 ms |
| **(liveness)** `_maybeSpeculate` — prepare + screen-refl + blur + extract | `verification_controller.dart:599-657` | **35-70 ms off-UI** + ~5 ms UI gates |
| **(post-blink, cache hit)** rate-limit + `findBestUser` | `verification_controller.dart:674-686, :753-772` | **~5-10 ms** |
| **(post-blink, cache miss)** prepare + screen-refl + blur + extract + match | `verification_controller.dart:687-748` | **~50-80 ms** |
| `VerifyUser.call` — Drift insert + last-verified upsert + probe-zero | `verify_user.dart:70-211` | **5-15 ms** |

**Steady-state UI-thread per-frame cost: ~25-40 ms. Match-attempt extra: +5-15 ms (cache hit) or +50-80 ms (cache miss).** XNNPACK + isolate-prep + speculative cache are the three reasons this is as tight as it is.

### 2.3 Result render → "Identity confirmed" spoken

| Stage | File:line | Cost |
|---|---|---|
| `state.copyWith(matchedUser, showResult:true)` triggers listener | `verification_controller.dart:778-784` → `verification_screen.dart:50, :252-273` | <1 ms |
| `addPostFrameCallback` → Material `showDialog` (default fade+scale transition) | `verification_screen.dart:258-272` | **~250 ms transition** |
| `AlertDialog` build + paint | `verification_result_dialog.dart:19-45` | ~5 ms |
| `ttsAnnouncer.speak()` — `stop` + `speak` (engine already prewarmed) | `tts_announcer.dart:79-89` | **~30-60 ms** to first audio |

**Decision → audible confirmation: ~280-310 ms.** Dialog transition is now the single biggest visible delay on the grant path.

---

## 3 · Remaining bottlenecks (worth optimising)

### 3.1 Camera cold-open is not prewarmed
`CameraController.initialize()` runs lazily in `camera_preview_widget.dart:_bootstrap` (line ~52). At ~250-500 ms on Android, this is the largest single stage in the "tap Verify → first frame" path. The prewarm provider already exists (`providers.dart:210-236`) but only warms `availableCameras()`, not the controller. **Win: ~300-500 ms on the cold path.**

### 3.2 Per-frame `print` statements in the camera widget
`camera_preview_widget.dart:78-82, 91-95` print on every frame (after the first 10, then once per second). `print()` on the `flutter` log channel is throttled to 12 KB/s; under load this can stall a frame. Same pattern exists in `liveness_state_machine.dart:84,93,103` (not on verify hot path) and the enrol controller. **Win: smoother preview during verify; ~5-10 ms reclaim per second of UI-thread CPU.**

### 3.3 Result dialog transition (~250 ms)
`showDialog()` uses Material's default route animation. For "instant grant" feel, an inline result panel (no route transition) would show the verdict immediately. **Win: ~150-200 ms of perceived latency on every grant.**

### 3.4 Per-frame state-copy + allocations
Each frame produces 2-4 `VerificationState` instances via `copyWith` and a fresh `issues: <String>[]`. Negligible per-frame (<1 ms) but at 30 fps that's ~30 ms/sec of GC pressure. **Win: minor — only act if profiler confirms allocations are causing GC pauses.**

### 3.5 `_warmTemplates` re-runs on every `dismissResult`
`verification_controller.dart:854`. For 50 users that's ~50 AES-GCM decrypts on each result-dialog close. Not on the first-attempt path; affects "retry after deny" latency. **Win: 30-120 ms on second-attempt readiness when bank size > 10.**

### 3.6 `Future.microtask` indirection in camera widget
`camera_preview_widget.dart:99` defers per-frame work by one microtask tick. The `_busy` back-pressure flag is therefore set *after* the camera plugin can queue the next frame. Drop rate is currently fine; complexity not worth it unless we want to switch to a queue-bounded executor. **Win: marginal; skip unless profile says otherwise.**

### 3.7 GPU delegate (TFLite) — not enabled
We ship XNNPACK (CPU SIMD). `tflite_flutter` 0.11.0 exposes `GpuDelegateV2` (OpenGL/OpenCL on Android). On devices with capable GPUs, the same MobileFaceNet at FP16 runs ~10-20 ms / extract vs ~20-30 ms on XNNPACK. Risk: FP16 precision drift can flip an axis on a vendor-buggy driver; the CPU-golden validation gate we built for XNNPACK applies here unchanged. **Win: ~10 ms / verify on supported devices; null on others (falls back).**

### 3.8 Cosine matcher works on a hot reference — minor allocation
`face_matching_service.dart:79-155` is SIMD'd but constructs a per-user grouping each call. For N=1000 templates this is microseconds; for N=10 it's already nothing. **Floor; do not touch.**

---

## 4 · Stages already at the floor (do not optimise)

| Stage | Why it's at the floor |
|---|---|
| Liveness challenge duration | User-paced — minimum ~300-600 ms for a blink regardless of code |
| Cosine matcher | Float32x4 SIMD, zero-copy `asFloat32x4List` views — 192-D dot in 48 FMAs |
| ML Kit `FaceDetectorMode.fast` | Native Google blob; no faster public option |
| MobileFaceNet inference (XNNPACK, 65/65 nodes delegated) | Model itself is the limit at FP32. INT8 quantization could buy ~30% but requires re-enrolling everyone |
| AES-GCM template decrypt | Platform-native crypto |
| Motion variance / screen reflection / blur gates | All <0.5 ms, pure integer ops |
| Probe zeroing | 192 stores, ~µs |

---

## 5 · Comparison with iOS Face ID — the structural gap

| Capability | iPhone Face ID | This app |
|---|---|---|
| Sensor | 30 k-dot IR projector + IR camera + flood illuminator + structured-light depth | 2D front RGB |
| Liveness | Hardware depth + IR (passive, instantaneous) | User-paced **active** challenge (blink / mouth / turn) |
| Inference | Neural Engine ASIC, ~5-10 ms | XNNPACK on ARM CPU, ~20-30 ms |
| Camera open | Always-on attention mode | Cold `CameraController.initialize` 250-500 ms |
| Match | Single enrolled identity (1-to-1) | Open-set 1-to-N with runner-up margin |
| End-to-end published | **~500-700 ms** including raise-to-wake | — |
| End-to-end us (cold tap → grant) | — | **~1500-3000 ms**, dominated by camera open + liveness wait |
| End-to-end us (warm, instant blink) | — | **~500-750 ms post-blink**: detect (~25) + cached probe + match (<10) + dialog (~250) + speak (~50) |

**The gap is the liveness model, not the compute.** Face ID's depth+IR sensor delivers the bits the moment the user looks. We require the user to perform a motion the system can observe in 2D, and that motion has a physiological floor (~300-400 ms for a blink). Bridging the structural gap would need either:
- Adding TrueDepth-like hardware (only on iOS, only on Pro models) → out of scope.
- A passive on-device PAD classifier strong enough to replace the active challenge → see §9.4.

Without one of those, **no optimisation in this codebase reduces below ~500 ms for the granting-to-confirmed flow when starting cold from camera-open.**

---

## 6 · Recommended hit-list

Ordered by user-visible win per hour of effort.

### Tier 1 — high-leverage, no architectural change

| # | Change | Effort | Risk | Saving |
|---|---|---|---|---|
| F-1 | **Prewarm the `CameraController`**. Move controller construction into a `keepAlive` provider that initializes during home → /verify navigation. Widget binds to the existing controller. | 2-3 hr | Low — needs careful lifecycle (controller binds to one widget at a time) | **~300-500 ms cold-path** |
| F-2 | **Strip per-frame `print` from `camera_preview_widget.dart`**. Gate behind `kDebugMode && const bool.fromEnvironment('PER_FRAME_LOG')`. Same for `liveness_state_machine.dart`. | 15 min | None | UI smoothness; ~5-10 ms/s reclaim |
| F-3 | **Inline result panel** in place of `showDialog`. Render the grant/deny verdict as part of the verify-screen tree instead of a Material dialog route. | 2 hr | Low — UX change | **~150-200 ms perceived** on grant |
| F-4 | **Skip `_warmTemplates` on `dismissResult` when bank is unchanged.** Track a "users-mutated since enter" flag set by enrol/delete; only re-decrypt when set. | 1 hr | Low | ~30-120 ms on retry-after-deny |

### Tier 2 — meaningful win, modest complexity

| # | Change | Effort | Risk | Saving |
|---|---|---|---|---|
| F-5 | **TFLite GPU delegate (opt-in, validated)**. Mirror the XNNPACK selection pattern: try GPU → CPU golden cosine compare → keep whichever wins. Telemetry to `/debug/health`. | 3-4 hr | Medium — vendor-driver variance, FP16 axis-flip on a small slice of devices | **~10 ms / extract on supported chips** |
| F-6 | **Lower per-frame state-copy churn**. Coalesce sibling `copyWith` calls into a single state mutation per frame. Replace per-frame `<String>[]` issues allocation with a reused buffer in `QualityAssessor`. | 2 hr | Low | ~1-2 ms/frame GC pressure reduction |

### Tier 3 — accept-or-defer

| # | Change | Effort | Risk | Saving |
|---|---|---|---|---|
| F-7 | **MediaPipe Face Detector swap**. ~3-5 ms faster than ML Kit on mid-range Android. | 1-2 days | High — new dependency, iOS story (preview), API differences | ~5 ms/frame |
| F-8 | **INT8 quantized MobileFaceNet**. ~30% inference saving. | 2 days + model | Very high — requires re-enrolling every existing user (different feature space) | ~7-10 ms / extract |
| F-9 | **Native NV21 decoder via platform channel**. We've already declined this in Phase D; the win moved off-thread (Phase D) and the wall-clock saving is small. | 1 day | Medium | ~6 ms / verify |
| F-10 | **PAD model replaces active challenge**. Silent-Face-Anti-Spoofing (MIT, ~1.5 MB) lets us drop the blink challenge for passive liveness. | 3-5 days + model audit | Very high — security model change, requires PAD calibration and field validation | **~500-1000 ms** (eliminates entire liveness wait) |

**My recommendation:** ship **F-1 through F-4** as a focused batch. Together they pull the cold tap→grant path from ~1500-3000 ms down to roughly ~700-1200 ms and the warm grant-to-confirmed perceived latency from ~280 ms down to ~80 ms. Tier 2 (F-5, F-6) is good follow-up. Tier 3 should each be scoped separately because the trade-offs are deeper.

---

## 7 · What NOT to do

- **Disable liveness for speed.** This is the single biggest latency contributor but it's the load-bearing anti-spoof gate alongside motion + screen-refl + device-motion. Removing it without a vetted PAD model regresses security.
- **Drop the cosine margin** (`verifyUserMargin = 0.04`). It's the open-set safety against an unrelated user landing in the 0.75-0.85 cosine band. Tightening it for a "faster grant" trades FAR for latency we don't need.
- **Increase camera resolution.** `medium` (640×480) is the sweet spot. Going to `high` 2-3× the detect cost; going to `low` (320×240) degrades ML Kit accuracy on dim faces.
- **Frame-skip in the verify path.** Each skipped frame is a missed blink edge. The existing `_busy` back-pressure already drops frames when the pipeline is saturated.
- **Cache the embedding across attempts.** The speculative-probe cache already covers the within-attempt latency win; persisting it across attempts breaks the security model (probe-zeroing exists for a reason).

---

## 8 · Benchmark targets

After Tier 1, the realistic targets on a Pixel-6-class mid-range device in `--release` mode:

| Stage | Current best (today) | Target post-F-1..F-4 |
|---|---|---|
| Home tap → first preview frame | 400-900 ms cold | **150-300 ms cold** (F-1) |
| Home tap → first preview frame (warm screen revisit) | 80-150 ms | 60-100 ms |
| Per-frame detect + quality + gates | 25-40 ms | 22-35 ms (F-2) |
| Liveness completion (user-paced) | 1500-3500 ms | unchanged (user time) |
| Post-blink → "Verified!" state | 5-15 ms (cache hit) / 50-80 ms (miss) | unchanged (already at floor) |
| State → result visible to user | ~250 ms (dialog transition) | **~30-60 ms** (F-3 inline panel) |
| Result visible → TTS first audio | ~30-60 ms | unchanged |
| **End-to-end perceived (warm, instant blink)** | ~500-750 ms | **~280-450 ms** |
| End-to-end perceived (cold tap-to-grant) | ~1500-3000 ms | **~600-1200 ms** |

After Tier 2 (F-5 GPU + F-6 alloc): subtract ~10-15 ms per attempt.

For comparison, Face ID's published wall-clock is ~500-700 ms. Post-Tier-1 we'd be **structurally competitive** within the limit of what 2D+active-liveness can deliver.

---

## 9 · Security & spoof considerations

### 9.1 The current anti-spoof stack stays

Motion variance + screen reflection + device-motion (L3) + randomised challenge (L2) + embedding sanity (A3) + rate limiter. None are removed by the Tier 1 / Tier 2 work proposed.

### 9.2 Speculation is already safe under the gates

`_maybeSpeculate` runs the same screen-refl + blur gates as `_runMatch` slow path at cache time. The fast path inherits the gate-pass verdict, not a free bypass. This was an explicit security review during O-5.

### 9.3 Probe zeroing is preserved on the fast path

`VerifyUser.call`'s `finally` zeros the probe regardless of whether it came from the extractor or from a caller-supplied embedding. Tested in `verify_user_test.dart` (`O-5 fast path: fast-path probe is zeroed after the call`).

### 9.4 PAD model (F-10) would let us drop the active challenge

Silent-Face-Anti-Spoofing (MIT-licensed, ~1.5 MB checkpoint) is a passive PAD classifier — runs on the same RGB frame, no extra hardware. If we ship it AND the existing stack, we could conditionally skip the blink challenge for high-quality frames, recovering ~500-1500 ms of user-time. Open questions before pursuing:
- Calibration on our user demographic (PAD models tend to FRR on darker skin tones at default thresholds — needs field study).
- License + checkpoint provenance audit.
- A separate model = another asset bundle + version + cold-start cost.

**Not a Tier-1 ask. Surface separately when this becomes a product priority.**

---

## 10 · Suggested architecture changes (none needed for Tier 1)

The current architecture (Riverpod providers, `keepAlive` embedding isolate, single `verification_controller` orchestrating the FSM) is well-shaped for these wins. The only structural change Tier 1 introduces is **camera controller lifecycle** moving from widget-owned to provider-owned (F-1). Existing widget continues to render the preview but binds to the long-lived controller instead of constructing it.

No changes proposed for:
- Embedding isolate wire protocol (covers prepare + extract via single-flight slot, all good).
- Database schema or template encoding.
- Liveness FSM structure.
- Match logic.

---

## 11 · Open questions to resolve before code changes

1. **F-1 approval:** is moving `CameraController` lifetime to a provider acceptable? It does mean the camera stays open across screen transitions (until home idle / app background), which costs ~3-5% battery on long-running sessions.
2. **F-3 UX:** is replacing the `showDialog` flow with an inline result panel acceptable? The dialog is currently the canonical "click-to-dismiss" surface; we'd need an equivalent dismiss affordance.
3. **F-4 cache validity:** what's the freshness contract for the active-templates bank? Re-decrypt on every screen entry is currently OK; we'd switch to "re-decrypt only when the user list mutated".
4. **F-5 GPU delegate:** willing to accept the device-variance risk (cosine-validated fallback to CPU) for the ~10 ms / extract win?
5. **Tier 3 PAD model (F-10):** field study window available?

---

## 12 · Recommendation summary

**Proceed with F-1, F-2, F-3, F-4** as a single coherent perf batch. Expected user-visible result: warm-path post-blink latency drops from ~280 ms to ~80 ms (perceived "instant"); cold tap-to-grant drops from ~1500-3000 ms to ~600-1200 ms (perceived "fast"). Implementation order:

1. F-2 (per-frame print strip) — 15 min, no risk, immediate UI smoothness.
2. F-1 (camera prewarm) — biggest cold-path win.
3. F-4 (skip redundant `_warmTemplates`) — quick refactor.
4. F-3 (inline result panel) — biggest warm-path win, UX-visible.
5. Tests + smoke on device.
6. Re-baseline against §8 targets.

**Tier 2 (F-5 GPU delegate, F-6 alloc)** as a follow-up batch after Tier 1 lands and is verified on-device.

**Tier 3 items (F-7..F-10)** stay as proposals — each deserves its own decision because the trade-off space is meaningfully different.

---

*End of analysis. No code has been modified. Proceed only after explicit approval of which tier(s) to implement.*
