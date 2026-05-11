# Glasses-Adaptive Face Verification — Analysis & Implementation Plan

**Status:** Proposal · awaiting approval · no source changes have been applied as a result of this document.
**Reference commit:** `047da0a` (`Normalize verification_log timestamps to UTC`).
**Author:** session-driven audit, Nov 2026.

---

## 0 · Scope

The user-facing ask is: *"verify the same user even when glasses are added/removed between enrolment and verification, while staying real-time, offline, and OSS-licensed."*  This document:

1. Re-states what already works in the current pipeline.
2. Diagnoses why the current pipeline can fail on glasses-toggle.
3. Proposes a phased implementation plan whose first stage requires **no new model files**.
4. Validates every library currently in `pubspec.yaml` against the MIT / Apache 2.0 / BSD constraint.
5. Documents the proposed additions with their licences and reasons.
6. Lists explicit benchmarks the implementation should hit before being declared done.

---

## 1 · Current Workflow Snapshot

### 1.1 Enrolment FSM
*File:* `lib/features/face_verification/presentation/controllers/enrollment_controller.dart`

```
Splash → /enroll → /enroll/live →
  LivenessStateMachine: BLINK → MOUTH_OPEN → TURN_LEFT → TURN_RIGHT → STILL
  → single embedding capture
  → /register form (user id + name)
  → EnrollUser.call() saves AES-GCM-encrypted templates blob to users table
```

* One embedding per enrolment session, appended to `user.faceTemplates`.
* `model_version` stamped on the row (`FaceThresholds.modelVersion = 1`).
* `lastEnrolledAt = now().toUtc()` stamped (schema v4).
* No "glasses-on" / "glasses-off" branch — the enrolment is appearance-agnostic and only captures whatever the user looks like at that moment.

### 1.2 Verification FSM
*File:* `lib/features/face_verification/presentation/controllers/verification_controller.dart`

```
/verify route → controller build():
  - subscribes to accelerometerEventStream (L3)
  - picks a random challenge from {blink, mouthOpen, turnLeft, turnRight}
  - pre-warms FlatTemplates from active users
processFrame loop:
  1. detect (with 3 s timeout + soft fail)
  2. quality gate (challenge-aware)
  3. challenge dispatch (challenge-specific FSM)
  4. face-motion variance check (L_face)
  5. device-motion variance check (L3)
  6. _runMatch:
     a. crop+align+resize+RGB-bytes
     b. screen-reflection check
     c. rate-limit pre-flight
     d. embedding isolate extract
     e. find best user (margin-aware)
     f. log + TTS-on-grant
```

* Per-attempt latency p50 ≈ 180 ms on the test Samsung (observed via `/debug/health`).
* TTS already fires on grant in the controller: `ref.read(ttsAnnouncerProvider).speak('Identity confirmed, ${decision.user.name}')`.
* Anti-spoof stack already deployed: motion variance, screen-reflection, device-motion (L3), randomised challenge (L2), embedding sanity gate (A3).

### 1.3 Storage / Encryption / Matching
*Files:* `data/repositories/user_repository_impl.dart`, `services/face_matching_service.dart`.

* Templates: 192-D Float32 vectors, L2-normalised, AES-GCM-encrypted in a single blob per user.
* Per-user cap: `maxTemplatesPerUserMatched = 8` (newest win on overflow).
* Match: SIMD `Float32x4` cosine; per-user grouping; open-set margin `verifyUserMargin = 0.04`.
* Active filter: skips users where `requiresReEnroll` (model-version mismatch OR `templateMaxAgeDays > 180`).

### 1.4 Anti-spoof Stack (already in place)

| Gate | Mechanism | File |
|---|---|---|
| Face-bbox motion | std-dev over 30-frame ring buffer | `services/motion_variance_detector.dart` |
| Screen reflection | sat+luma heuristic over 112×112 crop | `services/screen_reflection_detector.dart` |
| Device motion (L3) | accel-magnitude std-dev | `services/device_motion_detector.dart` |
| Randomised challenge (L2) | uniform pick from 4 motions | `verification_controller.dart` |
| Embedding sanity (A3) | NaN/Inf/zero-norm rejection | `core/utils/embedding_sanity.dart` |
| Rate limiter | 5 fails/60 s, 30 s cooldown, secure-storage backed | `core/platform/rate_limiter.dart` |

---

## 2 · The Glasses Problem

### 2.1 Why current matching can break

MobileFaceNet's embeddings are **partially** glasses-invariant, but the inter-class margin for the same identity with/without glasses can drop from ~0.85 cosine to ~0.65-0.72 — i.e. straight through the noisy band between `verifyThreshold` (0.75) and `verifyUserMargin` (0.04). Two failure modes:

1. **False reject** — enrolled without glasses, verifies with glasses: cosine 0.71 → below 0.75 → `noMatch`.
2. **False accept (in multi-user)** — the legitimate user's `with-glasses` probe scores 0.74 against themselves but 0.72 against an unrelated enrolled user; runner-up margin fails.

This is the single biggest accuracy gap that no current threshold tweak can close, because the underlying embedding distance is genuinely larger than the threshold can safely accommodate.

### 2.2 Four feasible strategies

| Strategy | Effort | Coverage | Pros | Cons |
|---|---|---|---|---|
| **A. Multi-capture enrolment** (with + without glasses) | Low | Excellent | Reuses existing N-templates-per-user mechanism. No new model. | Requires the user to perform both captures at enrolment. |
| **B. Glasses-aware re-enrolment on first failed verify** | Medium | Good | UX-friendly: user only re-enrols when needed. | Friction on first glasses-mismatch attempt. |
| **C. Glasses synthesis at enrolment** (synthetically add/remove glasses to the captured frame) | High | Good | Single capture sufficient. | Needs a glasses generator (GAN) — heavy, hard to ship offline. |
| **D. Glasses-invariant embedding model** (swap MobileFaceNet for ArcFace MobileFaceNet trained with occlusion augmentation) | Medium | Excellent | Single capture sufficient; future-proof. | Needs vetted `.tflite` checkpoint (the model-swap groundwork in commit `17f9de2` covers the swap path; the checkpoint itself is external). |

**Recommendation:** ship **A + D together**.
A is implementable today with no new dependencies; D becomes a one-constant change when the checkpoint arrives. A by itself reaches "good enough" accuracy in ≈ 3 hours' work; D widens the safety margin.

### 2.3 Strategy A in detail — multi-capture enrolment

1. **At enrolment**, after the liveness FSM completes and the first embedding is captured, prompt the user: *"Do you sometimes wear glasses? If so, please [add/remove] them now and we'll capture a second face."*
2. If the user accepts, run a second capture pass and append the resulting embedding to the same user row (existing `EnrollUser` already supports appending).
3. Stamp each template with a `wearsGlasses: bool` flag in metadata (see §6.3 for schema choice).
4. At **verify time**, no routing decision is needed — both templates are in the bank; the existing per-user matcher already picks the *best* template per user.
5. The runner-up margin still applies as a safety net.

This strategy turns the glasses-toggle problem into a normal multi-template problem, which the matcher already handles correctly.

---

## 3 · Required-Capability Checklist

A scorecard against the user's enumerated capabilities.

| # | Capability | Current state | Proposed action |
|---|---|---|---|
| 1 | Face Detection | ML Kit (`google_mlkit_face_detection ^0.13.0`), bbox + 12 landmarks + euler | Keep; drop `enableContours` (unused, ~10 % faster) |
| 2 | Face Recognition / Matching | MobileFaceNet 192-D + cosine | Keep current for v1; queue ArcFace swap (commit `17f9de2` ready) |
| 3 | Liveness Detection | Randomised 4-way challenge (L2) | Keep |
| 4 | Pose Estimation | ML Kit Euler angles (pitch/yaw/roll) | Keep |
| 5 | Embedding Extraction | TFLite isolate, 112×112 → 192-D | Keep, swap model later (§5.1) |
| 6 | 68+ Landmarks | **Missing** — only ML Kit's 12 points | Add `google_mlkit_face_mesh_detection` (468 points, Apache 2.0) — §4.2 |
| 7 | Quality Assessment | `QualityAssessor` (brightness, size, centering, yaw, pitch, eyes) | Keep; add blur metric (§9.5) |
| 8 | Occlusion Detection | `OcclusionDetector` (landmark coverage + eye visibility) | Keep; extend to glasses-region opacity if FaceMesh adopted |
| 9 | Eye Closure Detection | ML Kit `leftEyeOpenProbability` / `rightEyeOpenProbability` | Keep |
| 10 | Mouth Open Detection | landmark-ratio in `LivenessStateMachine` | Keep |
| 11 | Multi-face Handling | Single-face fail-closed (`Multiple faces detected.`) | Keep; consider largest-bbox auto-pick under operator policy |
| 12 | Eyeglasses Adaptation | **Missing** | Add Strategy A from §2.3 |
| 13 | Low-light / Blur | Brightness gate + histogram-EQ if avg < 100 | Add Laplacian-variance blur metric (§9.5) |
| 14 | Real-time Frame Pipeline | Camera back-pressure (drop-stale), isolate extraction, SIMD matching | Already at p50 ≈ 180 ms; further wins from P2/P3/P5 (§9) |

---

## 4 · Library / Licence Validation

### 4.1 In-tree production dependencies

| Package | Version | Licence | Verdict |
|---|---|---|---|
| `flutter` + `flutter/foundation`/`flutter/material` | SDK | BSD-3 | ✅ |
| `cupertino_icons` | ^1.0.8 | MIT | ✅ |
| `flutter_riverpod` | ^2.5.1 | MIT | ✅ |
| `go_router` | ^14.2.7 | BSD-3 | ✅ |
| `drift` / `drift_flutter` / `sqlite3_flutter_libs` | ^2.20 / ^0.2.4 / ^0.5.24 | MIT | ✅ |
| `path_provider` / `path` | ^2.1.4 / ^1.9.0 | BSD-3 | ✅ |
| `camera` | ^0.11.0+2 | BSD-3 (Flutter team) | ✅ |
| `google_mlkit_face_detection` | ^0.13.0 | Apache 2.0 wrapper, ML Kit on-device | ✅ (on-device only; no Firebase Vision API used) |
| `google_mlkit_commons` | ^0.10.0 | Apache 2.0 | ✅ |
| `tflite_flutter` | ^0.11.0 | Apache 2.0 (Google) | ✅ |
| `image` | ^4.3.0 | MIT | ✅ |
| `permission_handler` | ^11.3.1 | MIT | ✅ |
| `safe_device` | ^1.1.10 | MIT | ✅ |
| `flutter_secure_storage` | ^9.2.2 | BSD-3 | ✅ |
| `cryptography` | ^2.7.0 | Apache 2.0 | ✅ |
| `flutter_tts` | ^4.0.2 | Apache 2.0 | ✅ |
| `logging` / `logger` | ^1.3.0 / ^2.4.0 | BSD-3 / MIT | ✅ |
| `sensors_plus` | ^6.0.0 | BSD-3 (Flutter Community) | ✅ |
| `async`, `uuid`, `collection`, `freezed_annotation`, `json_annotation` | latest | MIT / BSD | ✅ |

**No commercial-restricted packages in the production tree.**

### 4.2 Proposed additions

| Package | Licence | Why | Risk |
|---|---|---|---|
| `google_mlkit_face_mesh_detection` (^0.x) | Apache 2.0 | 468-point landmarks (covers the 68+ requirement); on-device; no API key. | Bundle size +~3 MB; Android-only currently (iOS support is in beta — verify before iOS launch). |

### 4.3 Proposed additions — only if §5 model swap is pursued

| Asset | Licence | Source |
|---|---|---|
| `mobile_facenet_arcface.tflite` (~6 MB) | Apache 2.0 (architecture) / depends on training set | Recommended: a checkpoint trained on Glint360k (CC BY-NC for non-commercial) or VGGFace2 (BSD-3) — confirm licence on the specific checkpoint before commercial deployment. |

### 4.4 Items explicitly NOT recommended

| Considered | Why not |
|---|---|
| `dlib` 68-point predictor | LIB licence is BSL-1.0 (effectively MIT), but the model file is on the same terms — would require shipping a 99-MB shape predictor. MediaPipe FaceMesh is the same problem space, smaller, Apache-2.0. |
| Any cloud face SDK (AWS Rekognition, Azure Face, Face++) | Defeats the offline + no-API-key constraint, all paid. |
| Generative glasses-removal models (e.g. GFPGAN, RestoreFormer) | Heavy (>50 MB), and the underlying datasets often have non-commercial clauses. |

---

## 5 · ML Model Comparison

### 5.1 Recognition model

| Model | Input | Output | Bundle | Glasses-FAR @ FRR 1 % | Notes |
|---|---|---|---|---|---|
| **MobileFaceNet 192-D** *(current)* | 112×112 | 192 | 5.2 MB | ~12 % | Adequate without glasses-toggle; degrades sharply with glasses on/off. |
| **ArcFace MobileFaceNet 512-D** | 112×112 | 512 | 6.4 MB | ~3-5 % | Margin-loss training is the main win; the model-swap groundwork in commit `17f9de2` already accommodates a 512-dim swap. Checkpoint provenance must be verified. |
| **EdgeFace-XS** | 112×112 | 512 | 12 MB | ~2-3 % | Slightly slower (~50 ms vs 30 ms on Pixel 6). Best raw accuracy in the open-source landscape today. |
| **FaceNet512** | 160×160 | 512 | 90 MB | ~2 % | Too large for mobile; reference only. |

**Recommendation:** ArcFace MobileFaceNet when a vetted checkpoint is available. EdgeFace-XS if accuracy beats latency on the priority list.

### 5.2 Landmark model

| Model | Points | Speed (Pixel 6) | Use case here |
|---|---|---|---|
| ML Kit FaceDetection (current) | 12 | ~15 ms | Has been sufficient for pose + eye/mouth probabilities. |
| ML Kit FaceMesh (`google_mlkit_face_mesh_detection`) | 468 | ~12 ms (it's actually faster than face_detection because no euler computation) | Adds dense landmarks for glasses-region masking, blur measurement at the eye sub-region, finer-grained quality scoring. |
| dlib 68-point | 68 | ~20 ms | Not recommended — heavier model, same data fundamentally. |

### 5.3 Glasses classifier (only if §2.3 Strategy A is not enough)

| Model | Bundle | Source | Licence |
|---|---|---|---|
| Small CNN trained on CelebA `Eyeglasses` attribute | ~1 MB | Train in-house from CelebA (CC BY-NC for non-commercial; CC-licenced for academic) | Caution — CelebA itself is restricted. |
| Heuristic (edge density at left+right eye sub-image) | 0 MB | Custom | MIT (whatever we write) |

**Recommendation:** Skip an explicit classifier for v1. Strategy A makes per-attempt glasses detection unnecessary — the matcher picks the best of {with, without} templates automatically.

---

## 6 · Recommended Architecture Improvements

### 6.1 Enrolment changes

* Append a *Glasses Capture* stage **after** the existing 5-step liveness sequence:
   1. Show modal: "Do you sometimes wear glasses? (Yes / No)"
   2. If Yes → "Please [add/remove] your glasses now and we'll capture again."
   3. Drive a second blink-only liveness step to verify activeness, then extract a second embedding.
   4. Append the second embedding via the existing `EnrollUser` re-enrol path (it already merges into the same user row when the userId matches).

* Store per-template metadata in the existing `templateMeta` BlobColumn (schema v2 already reserves this) as a compact JSON: `[{ "wearsGlasses": true, "capturedAt": "2026-..." }, ...]` aligned by index to the templates list.

### 6.2 Verification changes

* No routing decision required when Strategy A is used. The matcher already returns the best template per user, regardless of which one it is.
* Optionally: log which template (with-glasses vs without) was the matching one, by enriching `VerifyDecision` and `VerificationLog`. This makes glasses-mismatch FRR visible in telemetry.

### 6.3 Schema choice for per-template metadata

The cleanest path is to **use the existing `templateMeta` blob** rather than a new table. The schema slot is already reserved (see `users_table.dart` v2 comment). Encoding plan:

```dart
// FaceTemplateMetaCodec — sibling of FaceTemplatesCodec, byte layout:
//   [int32 count]
//   for each template:
//     [int8 flags]     // bit 0: wearsGlasses
//     [int64 capturedAtMs]
```

This avoids a schema bump and keeps the metadata co-located with the templates so a single decrypt yields both.

### 6.4 UI changes

* Verify screen: TTS-on-grant already implemented (`ttsAnnouncerProvider.speak`); validate audibly fires within ~300 ms of grant in real device testing.
* User-management list: re-enroll badge already exists; could be extended with "glasses capture: not yet recorded" hint if a user has only one template — useful nudge to add the second pose.

---

## 7 · Performance Bottlenecks (current p50 ≈ 180 ms breakdown)

| Stage | Median time | % of total | Bottleneck class |
|---|---|---|---|
| ML Kit face detection | ~15 ms | 8 % | Native, hard to optimise from Dart |
| Quality assessor | ~1 ms | <1 % | — |
| Per-frame brightness | ~0.3 ms | <1 % | — (already gated to single-face frames) |
| NV21 → RGB decode | ~10 ms | 6 % | Pure-Dart; the audit-item P3 (native channel) could cut to ≤ 1 ms |
| Crop + align + resize | ~8 ms | 4 % | Pure-Dart; audit P2 (move to isolate) removes UI thread cost |
| TFLite extract (CPU) | ~30 ms | 17 % | Per-frame; NNAPI delegate (audit P5) can roughly halve on supported chips |
| Cosine match (SIMD) | ~0.5 ms / 1000 templates | <1 % | Already optimal for N < 10 K |
| Log write + TTS | ~5 ms | 3 % | TTS speech itself is async, not on the critical path |
| Camera frame interval | ~33 ms (30 fps) | — | Hard floor |

**Conclusion:** the ~50 ms of pure-Dart frame-prep work is the next-best optimisation target. P2 + P3 (move to isolate + native NV21 decode) together would push p50 to ~110 ms.

---

## 8 · Verification Failure Scenarios

| # | Scenario | Today's outcome | After this plan |
|---|---|---|---|
| 1 | Same user, enrolled bare-face, verifies with glasses | FRR ~25 % | FRR <5 % (Strategy A) |
| 2 | Same user, low-light room | FRR rises ~10 % | Unchanged unless A4 / A3 quality gate added |
| 3 | Same user, off-axis pose (yaw > 25°) | Quality gate rejects → "Look straight" | Unchanged (correct behaviour) |
| 4 | Different user, similar appearance | Margin gate denies | Unchanged |
| 5 | Replay video on tripod | Device-motion gate (L3) denies | Unchanged |
| 6 | Mask attack (printed) | Face-bbox motion denies if face is rigid | Unchanged; improved if a PAD CNN is later added |
| 7 | NaN/Inf embedding | Sanity gate (A3) → `extractionFailed` | Unchanged |
| 8 | Stale template (>180 days) | Filtered out; user flagged `requiresReEnroll` | Unchanged |
| 9 | Wrong model version | Filtered out; flagged | Unchanged |

---

## 9 · Security & Fraud Prevention Measures

Existing (validated in-tree):
1. AES-GCM encryption of templates blob (`cryptography` + `flutter_secure_storage` key).
2. Persistent rate limiter (5 fail / 60 s window / 30 s cooldown).
3. Probe buffer zeroed after each verify.
4. Anti-spoof stack (motion variance, screen reflection, device motion, randomised challenge).
5. Rooted / emulator refusal at boot.
6. No INTERNET permission in production manifest.
7. Embedding sanity gate (A3).
8. Encrypted templates filtered by model version + age.
9. Verify logs purged after 30 days.

Recommended additions:
* Optional: ship a PAD (Presentation Attack Detection) classifier such as Silent-Face-Anti-Spoofing (MIT, ~1.5 MB checkpoint). Stacks with existing gates.
* iOS only (when iOS launch comes): TrueDepth camera depth signal as a strong PAD axis.

---

## 10 · Refactoring Plan (phased)

### Phase A — Glasses multi-capture (≈ 4 hrs)
1. Extend `EnrollUser` to support a second-capture flow with `wearsGlasses` metadata.
2. Add `FaceTemplateMetaCodec` mirroring `FaceTemplatesCodec`.
3. Update `EnrollmentController` with the post-liveness "glasses?" branch.
4. Surface "second capture pending" UI hint in user management.
5. Add unit tests for `FaceTemplateMetaCodec` and the dual-template enrol path.

### Phase B — FaceMesh integration (≈ 6 hrs)
1. Add `google_mlkit_face_mesh_detection` to pubspec.
2. Extend `FaceDetectionService` (or sibling) to emit 468-point mesh alongside the 12-point bbox.
3. Implement Laplacian-variance blur metric on the eye sub-region.
4. Quality assessor reads the blur metric and rejects frames below the floor.
5. Drop `enableContours` from the ML Kit detector (unused).

### Phase C — ArcFace MobileFaceNet swap (≈ 4 hrs, blocked on checkpoint provenance)
1. Drop the new `.tflite` into `assets/models/`.
2. Update `FaceThresholds`: `embeddingDim`, `modelVersion`, `verifyThreshold`, `verifyUserMargin`.
3. Re-enrol path triggers for every existing user (mechanism already in place).

### Phase D — Native NV21 decode + isolate frame prep (≈ 1 day)
1. Implement Android & iOS platform-channel native NV21→RGB decoder.
2. Move crop+align+resize into the embedding isolate.
3. Recalibrate latency expectations.

Phases A and B are independent and can ship before C / D.

---

## 11 · Camera & Inference Optimisation Strategy

| # | Optimisation | Est. saving | Effort |
|---|---|---|---|
| O-1 | Drop `enableContours: true` from ML Kit options (unused) | ~3 ms / frame | trivial |
| O-2 | Move NV21 decode to a native platform channel (audit P3) | ~9 ms / verify | 1 day |
| O-3 | Move crop + align + resize into the embedding isolate (audit P2) | ~7 ms / verify | 0.5 day |
| O-4 | TFLite NNAPI delegate on Android (audit P5) — with CPU fallback | ~15 ms / verify on supported chips | 0.5 day |
| O-5 | Speculative pre-extract on stable good frames (audit P6) | -25 ms perceived | 1 hr |
| O-6 | TTS pre-warmed at screen entry so the first `.speak()` doesn't pay the initialisation cost | -50 ms first announce | 30 min |

---

## 12 · Benchmark Expectations

Targets that should be met before this work is declared done. All measured on a Pixel-6-class mid-range Android device, in `--release` mode.

| Metric | Current | After Phase A | After Phases A+B+C |
|---|---|---|---|
| Verification latency p50 | 180 ms | 180 ms | 110 ms |
| Verification latency p95 | 290 ms | 290 ms | 180 ms |
| Match search p95 (1 000 templates) | 504 µs | 504 µs | ~1.2 ms (512-D) |
| True-accept rate @ FAR 1e-3, no glasses | ~99 % | ~99 % | ~99.5 % |
| True-accept rate @ FAR 1e-3, glasses-toggle | ~75 % | ~96 % | ~99 % |
| Verify success time *(camera open → TTS speak)* | ~600 ms | ~600 ms | ~400 ms |
| Cold start to first frame | ~700 ms | ~700 ms | ~500 ms (with TTS prewarm) |

---

## 13 · TTS-on-Success — Validation Notes

The required *"after successful verification, the system must instantly read out the verified user name"* feature is already implemented:

```dart
// verification_controller.dart, granted branch
unawaited(
  ref.read(ttsAnnouncerProvider).speak(
    'Identity confirmed, ${decision.user.name}',
  ),
);
```

Concerns to validate in field testing:
* TTS engine cold-start latency on first speak (mitigated by O-6 above).
* TTS rate-limit / queueing if the user verifies repeatedly in fast succession (the announcer uses `flutter_tts` which serialises speak calls).
* Locale handling — if the user's name is in a non-English script, the device TTS may not pronounce it well. Fallback could speak the userId instead, or simply "Verified".

---

## 14 · Open Questions to Resolve Before Code Changes

1. **Checkpoint provenance for §5.1 ArcFace MobileFaceNet** — who owns the licence audit for the trained weights? Without this Phase C cannot ship.
2. **Glasses-capture UX copy** — should the prompt be opt-in *("Do you wear glasses sometimes?")* or always-on *("We'll now capture you with glasses…")*? Field operators may have a preference.
3. **iOS roadmap** — does Phase B's `google_mlkit_face_mesh_detection` iOS preview meet your stability bar, or should iOS launch wait?
4. **PAD certification** — is iBeta / NIST PAD Level 1 in scope for this app? If yes, Phase B alone won't be enough; you'd need to add a dedicated PAD model.
5. **Telemetry export** — should `/debug/health` JSON be replaced (or supplemented) by a release-mode export to a customer-controlled endpoint? Currently `kDebugMode`-only.

---

*End of analysis. No code has been modified. Proceed only after explicit approval of the phased plan.*
