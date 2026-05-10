# Verify Identity Flow — Architecture & Implementation Recommendations

**Scope.** Section 1.5 of `docs/migration/01_project_analysis.md` plus the Manage
Users screen. This document is **planning only** — no code is changed by it.
Read it next to:

- `docs/migration/07_architecture.md` (layering and DI)
- `docs/migration/09_performance.md` (frame budget, isolate plan)
- `docs/migration/10_security.md` (encryption, rate-limit, anti-spoof)
- `docs/migration/13_test_strategy.md` (coverage targets)
- `docs/migration/05_database_migration.md` (schema rules)

The `verification_controller.dart` and supporting services already exist; the
**screen UI** (`verification_screen.dart`, `user_management_screen.dart`) and
several requirement-driven additions (TTS, verification log table, isolate
extraction, occlusion gate, rate limiter, fraud-prevention pipeline,
last-verification-time on the user row) are **not yet built**. This document
specifies how to add them without rewriting what works.

---

## 1. Goals re-stated as engineering acceptance criteria

| ID  | Requirement (from the brief)                                        | Acceptance criterion                                                                                            |
| --- | ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| G1  | Open camera **immediately** when "Verify Identity" tapped           | First camera frame visible ≤ 700 ms after tap on Pixel 6-class device; ≤ 1100 ms on Galaxy A21-class            |
| G2  | Ultra-fast real-time verification, ms-level response                | Embedding p95 ≤ 200 ms; cosine search p95 ≤ 8 ms / 1000 templates; granted-or-denied dialog ≤ 5 s after blink   |
| G3  | Announce user name on success                                       | TTS or visible banner reads "Identity confirmed: <name>" within 200 ms of the match decision                    |
| G4  | Match against locally stored encrypted templates                    | Templates decrypted in-memory only; no plaintext written to disk; flat bank pre-warmed once on screen entry     |
| G5  | All checks run in real time during verification                     | Detection → Quality → Liveness → Embedding → Match all complete inside one camera-frame back-pressure window    |
| G6  | Smooth UI during AI processing                                      | Preview ≥ 28 fps; no jank > 16 ms on the UI isolate during a verification                                       |
| G7  | Offline verification                                                | Airplane-mode pass; no `INTERNET` permission used at runtime                                                    |
| G8  | Manage Users: enrollment status, last-verify time, profile edit     | All four facts visible per row; offline editable; persists across app restart                                   |
| G9  | Multi-face / no-face / occlusion / spoof rejection                  | Each path emits a distinct `VerificationFailureReason` and visible instruction                                  |
| G10 | Enterprise-grade security                                           | AES-GCM at rest, rate-limited, root/jailbreak-aware, no PII in logs                                             |

---

## 2. Architectural overview

### 2.1 Stack decisions (already locked by 07_architecture.md)

| Concern             | Choice                                                                                  | Why                                                                                                     |
| ------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Pattern             | **Clean Architecture (Lite)** — Presentation → Domain → Data + horizontal Services      | Matches Android source layout; keeps codegen/tests small                                                |
| State management    | **Riverpod 2** (`Notifier` / `AsyncNotifier`)                                           | Compile-time safety, `autoDispose`, `keepAlive` for TFLite, no boilerplate for 5 screens                |
| Routing             | **`go_router`** with redirect-based gates                                               | Mirrors Android's `MainActivity` security/permission chain; deep-link safe                              |
| Local DB            | **Drift on SQLite (`sqlite3_flutter_libs`)** + per-row AES-GCM blob                     | See §5; SQLCipher rejected to keep iOS build simple                                                     |
| ML detector         | `google_mlkit_face_detection` (FAST mode, contours on)                                  | Drop-in replacement for Android ML Kit                                                                  |
| Embedding           | `tflite_flutter` with MobileFaceNet 112×112 → 192-D, XNNPack, 4 threads                 | Same model bytes as Android; embedding parity                                                           |
| Matcher             | Pure Dart cosine on `Float32List`; FFI shim deferred until N > 5000                     | Already implemented; ~6 ms p95 / 1000 templates                                                         |
| Anti-spoof (active) | Mandatory blink + (optional) mouth-open + occlusion gate                                | v1; passive texture-liveness deferred                                                                   |
| Crypto              | `package:cryptography` AES-GCM + `flutter_secure_storage` DEK                           | Already implemented; envelope encryption per row                                                        |

> **Reject** Bloc, GetX, Provider, GetIt, riverpod_generator, router_generator,
> SQLCipher, MediaPipe Tasks Vision (the analysis flagged it as experimental
> and unwired). MVVM is conceptually equivalent to Riverpod-Notifier here —
> document but don't add a parallel framework.

### 2.2 Layered placement of new code

Everything below is **net-new** unless noted "exists, extend". File names follow
`docs/migration/08_folder_structure.md` conventions (snake_case, mirrored under
`test/`).

```
lib/
├── core/
│   ├── constants/
│   │   └── thresholds.dart                  (exists, extend §3.4)
│   ├── platform/
│   │   ├── permission_check.dart            (exists)
│   │   ├── security_check.dart              (exists)
│   │   ├── tts_announcer.dart               NEW — wraps flutter_tts behind interface
│   │   └── rate_limiter.dart                NEW — verification attempt window
│   ├── isolates/
│   │   └── embedding_isolate.dart           NEW — long-lived isolate for TFLite
│   └── security/
│       └── template_crypto.dart             (exists)
│
├── data/
│   └── database/
│       ├── app_database.dart                (exists, schemaVersion bump §5.1)
│       ├── tables/
│       │   ├── users_table.dart             (exists, add lastVerifiedAt §5.1)
│       │   └── verification_logs_table.dart NEW
│       └── daos/
│           ├── user_dao.dart                (exists, add updateLastVerified)
│           └── verification_log_dao.dart    NEW
│
├── features/
│   └── face_verification/
│       ├── domain/
│       │   ├── entities/
│       │   │   ├── verification_failure.dart    NEW — sealed enum w/ reason
│       │   │   └── verification_log.dart        NEW
│       │   ├── repositories/
│       │   │   └── verification_log_repository.dart  NEW
│       │   └── usecases/
│       │       └── verify_user.dart              NEW — orchestrates pipeline
│       │
│       ├── data/
│       │   └── repositories/
│       │       ├── user_repository_impl.dart            (exists, add lastVerifiedAt)
│       │       └── verification_log_repository_impl.dart NEW
│       │
│       └── presentation/
│           ├── controllers/
│           │   ├── verification_controller.dart    (exists, refactor §3)
│           │   └── user_management_controller.dart (exists, extend §6)
│           ├── screens/
│           │   ├── verification_screen.dart        REPLACE stub
│           │   └── user_management_screen.dart     REPLACE stub
│           └── widgets/
│               ├── verification_status_bar.dart    NEW
│               ├── face_alignment_guide.dart       NEW (oval + colored ring)
│               ├── user_detail_sheet.dart          NEW (edit profile bottom sheet)
│               └── camera_preview_widget.dart      (exists)
└── ...
```

Tests mirror this tree under `test/` and `integration_test/`.

### 2.3 DI graph additions (Riverpod providers)

```
ttsAnnouncerProvider        Provider           (autoDispose-on-screen)
rateLimiterProvider         Provider           (app-wide singleton)
verificationLogRepoProvider Provider           (depends on dbProvider)
verifyUserUseCaseProvider   Provider           (depends on repos + services)
embeddingIsolateProvider    AsyncNotifier      (keepAlive; spawn once)
```

`verificationControllerProvider` stays `AutoDisposeNotifierProvider` so the
camera + state are torn down when the screen pops.

### 2.4 Sequence (single verification attempt)

```
User tap "Verify Identity"
  └─► go_router redirect
        ├─ securityStatusProvider.check()  → if rooted/emulator → /security
        └─ cameraPermissionProvider.check() → if denied → /permission

VerificationScreen.build()
  ├─ start CameraPreviewWidget (front, medium, NV21/BGRA8888)
  └─ controller._warmTemplates()  ← FlatTemplates pre-warmed once

CameraPreviewWidget._onCameraImage  ── back-pressure guard (_busy)
  └─ controller.processFrame(raw, mlKitInput)
        ├─ rateLimiter.check()                ← rejects if 5 fails / 60 s
        ├─ FaceDetectionService.detect()      ← ML Kit
        ├─ ─ if faces.length != 1 → emit Reason.{none|multi}
        ├─ QualityAssessor.assess()           ← brightness, size, centering, pose, eye-vis
        ├─ ─ if !ok → emit Reason.qualityFailed (with hints)
        ├─ Occlusion gate (§3.6)              ← landmark coverage
        ├─ ─ if occluded → emit Reason.occluded
        ├─ Liveness (mandatory blink, optional mouthOpen)
        ├─ ─ if !blinkPassed → emit "Blink to verify"
        ├─ Anti-replay heuristics (§7)        ← motion-vs-static, screen reflection
        ├─ ─ if spoof suspected → emit Reason.spoof
        ├─ embeddingIsolate.extract(crop, faceMeta) ← off-isolate TFLite
        ├─ FaceMatchingService.findBestMatch()
        ├─ ─ if score < 0.75 → emit Reason.noMatch
        └─ ─ else
             ├─ rateLimiter.reset()
             ├─ verificationLogRepo.append(success)
             ├─ userRepo.touchLastVerified(userId, now)
             ├─ ttsAnnouncer.speak("Identity confirmed, ${name}")
             └─ emit GrantedDialog(user)
```

The whole sequence runs inside the back-pressure window; the next frame is
discarded until this completes.

---

## 3. Verification controller — detailed implementation plan

### 3.1 State shape (extend the existing `VerificationState`)

Add the following without removing fields:

| Field                  | Type                     | Purpose                                                                  |
| ---------------------- | ------------------------ | ------------------------------------------------------------------------ |
| `failureReason`        | `VerificationFailure?`   | Sealed: none / multiFace / occluded / lowLight / spoof / blinkRequired …  |
| `mouthOpenRequested`   | `bool`                   | True when the policy demands mouth-open as second liveness factor        |
| `mouthOpenPassed`      | `bool`                   | Latched to true on close→open transition                                 |
| `attemptCount`         | `int`                    | Rolling counter inside the rate-limit window; surfaced for "X / 5"       |
| `phase`                | `VerifyPhase`            | `idle / scanning / liveness / matching / granted / denied / cooldown`    |
| `lastFrameAt`          | `DateTime`               | For timeout watchdog                                                     |

`VerifyPhase` is an explicit FSM rather than the current ad-hoc booleans —
makes UI conditionals simpler and tests deterministic.

### 3.2 Frame pipeline order (final)

1. **Cheap gate** — `state.phase != cooldown` and `!isVerifying` else drop.
2. **Watchdog** — if no frame change observed in last 12 s, transition to `denied(reason: timeout)`.
3. **Rate-limit check** — see §7.4.
4. **Detection** — single-shot ML Kit call.
5. **Cardinality** — `faces.length` 0 or >1 short-circuits to fail-with-instruction.
6. **Quality** — `QualityAssessor.assess(face, frame, brightness)` — already wired.
7. **Occlusion gate (NEW)** — see §3.6.
8. **Liveness** — mandatory blink (current code), then optional mouth-open if `policyRequiresMouthOpen`.
9. **Anti-replay heuristic** — see §7.
10. **Crop** — `BitmapUtils.cropFace` (25 % margin, exists).
11. **Embedding** — `embeddingIsolate.extract(...)` rather than inline run.
12. **Match** — `findBestMatch(probe, flat, count, threshold = 0.75)`.
13. **Decision** — granted, denied, or update best-similarity for HUD.

Steps 4–10 must complete in ≤ 70 ms on Pixel 6; only step 11 is allowed to
exceed a single frame interval (33 ms at 30 fps), which is what makes the
back-pressure model viable.

### 3.3 Isolate offload (`core/isolates/embedding_isolate.dart`)

Spawn a **long-lived** isolate at first verification entry; do not use
`Isolate.run` for every frame (cold-start cost ≈ 80 ms on low-end Android).

```
EmbeddingIsolate
  spawn() → loads TFLite + binds XNNPack, optional GpuDelegateV2/MetalDelegate
  extract(Crop, FaceMeta) → Float32List(192) via SendPort
  close()  → on ref.onDispose
```

Crop is sent as a **transferable `TransferableTypedData`** (RGB byte buffer,
pre-resized to 112×112 on the controller side to keep the wire payload at
37 632 bytes). Keep the GPU delegate guarded with try/catch and fall back to
CPU+XNNPack on init failure (consistent with Android's documented behavior).

> **Do NOT** spawn one isolate per frame — a single isolate with a request
> queue length of 1 (drop-newer-when-busy) is the sweet spot.

### 3.4 New thresholds (extend `core/constants/thresholds.dart`)

| Constant                       | Value      | Purpose                                                          |
| ------------------------------ | ---------- | ---------------------------------------------------------------- |
| `verifyTimeoutMs`              | 12 000     | Maximum wall-clock for one verification attempt                  |
| `frameStaleMs`                 | 1 500      | Watchdog for camera disconnect                                   |
| `lowLightBrightness`           | 35         | Below = "Move to better lighting" (slightly stricter than 45)    |
| `occlusionLandmarkMin`         | 4          | Required ML Kit landmarks present (eye L, eye R, nose, mouth)    |
| `replayMotionMaxStdPx`         | 0.8        | Bounding-box centroid variance below this for ≥ 1 s = static     |
| `replayMotionMinStdPx`         | 0.6        | Below this and reject — see §7.2                                 |
| `rateLimitMaxFailures`         | 5          | Per `rateLimitWindowMs`                                          |
| `rateLimitWindowMs`            | 60 000     | Sliding window                                                   |
| `rateLimitCooldownMs`          | 30 000     | Forced cooldown after exhaustion                                 |
| `mouthOpenStepRequired`        | `false`    | Default v1 — flip per deployment policy                          |
| `verifyMaxAttemptsBeforeReset` | 10         | Camera/pipeline reset (recover from a stuck state)               |

Pin every new constant in the existing `thresholds_parity_test.dart`.

### 3.5 The 10 required real-time checks — concrete map

| Required check (brief)              | Where it runs                                                                 | Notes                                                                                              |
| ----------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Face Detection                      | `FaceDetectionService.detect()` (ML Kit FAST + contours)                      | Already wired                                                                                      |
| Face Liveness Detection             | Active blink + optional mouth-open (`liveness_state_machine.dart`)            | Already wired (blink); mouth-open gated by policy flag                                             |
| Pose Estimation                     | `QualityAssessor` yaw/pitch limits + ML Kit `headEulerY/X`                    | Already wired                                                                                      |
| Face Template Extraction            | `FaceRecognitionService.extractEmbedding()` inside isolate                    | **Action**: move to isolate                                                                        |
| Face Matching                       | `FaceMatchingService.findBestMatch(threshold = 0.75)`                         | Already wired (pure Dart Float32List)                                                              |
| 68-Point Landmark Detection         | ML Kit returns ~9 landmarks + face contours (~133 contour points)             | **Action**: document — Google ML Kit does NOT return iBUG-68; the contour API gives equivalent or richer data. Use contours for occlusion + UI overlay. iBUG-68 is only required if a partner contract names it; in that case bring `face_landmarker.task` (MediaPipe) as a parallel detector. |
| Face Quality Calculation            | `QualityAssessor.assess()`                                                    | Already wired                                                                                      |
| Face Occlusion Detection            | New gate in controller (see §3.6)                                             | **Action**: implement                                                                              |
| Eye Closure Detection               | ML Kit `leftEyeOpenProbability` / `rightEyeOpenProbability`                   | Already used inside liveness                                                                       |
| Mouth Opening Check                 | `LivenessStateMachine._processMouthOpen()`                                    | Already wired (used in enroll); reuse for optional verify factor                                   |

### 3.6 Occlusion gate (NEW)

ML Kit gives `face.contours[FaceContourType.*]` — a list of points along eyes,
brows, lips, nose ridge, face oval. Two cheap heuristics:

1. **Coverage**: count of non-null contours; below 8 (out of ~12) → occluded.
2. **Eye visibility**: both `leftEyeOpenProbability` and `rightEyeOpenProbability`
   must be **non-null** for ≥ 2 consecutive frames in the non-blink phase.
   Persistently null = occluded (sunglasses, hand, scarf).

A third hand-mask heuristic (optional later): bounding box of face vs face
contour-oval — if oval is < 75 % of bbox, something is occluding part of the
detected face region.

Add `OcclusionDetector` as a pure-Dart helper in
`lib/services/occlusion_detector.dart` so the controller stays thin.

### 3.7 Why not add MediaPipe FaceLandmarker for the "68 points"?

The Android baseline has experimental `MediaPipeDetector.kt` (analysis §1.6)
not wired to any screen. ML Kit's contour API already gives finer-grained
landmarks than iBUG-68 for the gates we need (occlusion, blink, mouth). Pulling
MediaPipe into Flutter requires additional native plumbing and an extra model
asset (~2.6 MB). **Recommendation**: stay on ML Kit for v1; keep MediaPipe
behind a feature flag (`useMediaPipeLandmarks`) only if a contract demands the
literal 68-point output.

---

## 4. Manage Users screen — implementation plan

### 4.1 Information architecture (each row)

```
┌─────────────────────────────────────────────────────┐
│ ⬤ EMP-001                       [● Active]   ⋯       │
│    John Doe                                          │
│    Enrolled: 2026-04-12 · Templates: 3               │
│    Last verified: 2026-05-10 09:14   ← from log+row  │
│    Verifications today: 4 · Last result: ✓ Granted   │
└─────────────────────────────────────────────────────┘
```

- Active toggle ↔ `userManagementController.toggleActive`.
- Tap row ⇒ `UserDetailSheet` (bottom sheet) with: edit `name`, view template
  count, "Re-enroll" CTA (route to `/enroll` with prefilled userId), "Delete".
- Long-press / kebab menu ⇒ `DeleteUserDialog` (already exists).
- Empty-state widget when 0 users, with primary CTA "Enroll your first user".

### 4.2 Data sources

| Field shown                | Source                                                                                                                            |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Enrollment status          | `User.isActive`                                                                                                                   |
| Templates count            | `User.faceTemplates.length`                                                                                                       |
| Enrolled-at                | **NEW**: `enrolledAt` column on users table (default `now()` on insert) — see §5.1                                                |
| Last verified              | **NEW**: `lastVerifiedAt` column updated by use case                                                                              |
| Verifications today        | `verificationLogDao.countSince(userId, startOfDay)`                                                                               |
| Last verification status   | `verificationLogDao.latestForUser(userId)`                                                                                        |

Use `StreamProvider<List<UserManagementRowVm>>` that joins the two DAOs once
and re-emits on either `Users` or `VerificationLogs` changes.

### 4.3 Manage Users controller additions

```
class UserManagementController {
  Future<void> toggleActive(User u);           // exists
  Future<void> deleteUser(User u);             // exists
  Future<void> renameUser(User u, String new); // NEW
  Future<void> reEnroll(User u);               // NEW — pushes /enroll w/ args
  Stream<List<UserManagementRowVm>> watch();   // NEW — joined view
}
```

`UserManagementRowVm` is a presentation-only DTO; do not push it into the
domain layer.

### 4.4 Profile edit safety

- Only `name` is user-editable in v1. `userId` is the natural key — changing it
  breaks foreign-key intent on the verification log.
- Validate name: 1–80 chars, trimmed; reject empty.
- Wrap edits in a Drift transaction so the BLOB stays untouched (we don't want
  to re-encrypt templates on a name edit).

---

## 5. Local Database — final shape

### 5.1 Schema bump (Drift `schemaVersion = 2`)

**`users` table — add columns:**

| Column           | Type                              | Notes                                                                       |
| ---------------- | --------------------------------- | --------------------------------------------------------------------------- |
| `enrolledAt`     | `DateTimeColumn` (UTC)            | `withDefault(currentDateAndTime)`                                           |
| `lastVerifiedAt` | `DateTimeColumn` nullable         | Set by `VerifyUser` use case on success                                     |
| `templateMeta`   | `BlobColumn` nullable             | (Future) per-template provenance (model id, version) — additive, not v1    |

**New `verification_logs` table:**

| Column         | Type             | Notes                                                                  |
| -------------- | ---------------- | ---------------------------------------------------------------------- |
| `id`           | INTEGER PK auto  |                                                                        |
| `userId`       | TEXT nullable FK | NULL when no match (logged with reason)                                 |
| `at`           | DateTime         |                                                                        |
| `outcome`      | TEXT (enum)      | `granted` / `denied` / `error` / `rateLimited` / `spoof` …              |
| `failureReason`| TEXT nullable    | One of `VerificationFailure` cases                                      |
| `bestSimilarity` | REAL nullable | Bounded `[-1, 1]`; useful for tuning thresholds; **never** the embedding |
| `latencyMs`    | INTEGER          | End-to-end pipeline latency for this attempt                            |

Index `(userId, at DESC)` for the "verifications today" aggregate.

### 5.2 Migration

```
schemaVersion = 2
onUpgrade(from, to) {
  if (from < 2) {
    await m.addColumn(users, users.enrolledAt);
    await m.addColumn(users, users.lastVerifiedAt);
    await m.addColumn(users, users.templateMeta);
    await m.createTable(verificationLogs);
  }
}
```

**Hard rule** (per `05_database_migration.md`): no
`fallbackToDestructiveMigration`. All future bumps must be additive, with a
parity test that reads a v1 fixture DB and validates it upgrades cleanly.

### 5.3 Hive vs Isar vs SQLite — final recommendation table

| Aspect                       | Hive (v2)                            | Isar v3 / v4                              | SQLite via **Drift**                         |
| ---------------------------- | ------------------------------------ | ------------------------------------------ | -------------------------------------------- |
| Query model                  | Box-style key/value                  | Object DB w/ indexes                       | Relational + reactive streams                 |
| Encryption                   | Hive AES box (per-box)               | Isar v3 had AES; v4 dropped                | Per-row AES-GCM blob (already implemented)   |
| Schema migration             | Manual                               | Manual with caveats                        | First-class via Drift                         |
| Streams                      | Watch-by-key                         | Built-in                                   | `select.watch()` — already used               |
| iOS / Android maturity       | High                                 | Mixed (FFI complexity, v4 churn)           | Highest (sqlite3_flutter_libs, drift)        |
| Flutter Web                  | Yes                                  | Yes                                        | Yes (sql.js)                                 |
| Verification log query needs | Hard (no joins, no aggregates)       | OK                                         | Trivial (group-by, count, joins)             |
| Existing repo + crypto       | Reimpl needed                        | Reimpl needed                              | **Already wired**                             |

**Decision**: stay on **Drift / SQLite**. Templates remain per-row AES-GCM
blobs (envelope encryption) — this is already implemented and matches the
threat model in `10_security.md`. Hive/Isar add risk and engineering effort
for no measurable benefit at our data sizes (≤ a few thousand users).

### 5.4 Backup + retention

- Set Android `allowBackup="false"` and exclude `databases/` and
  `app_flutter/user_faces/` via `data_extraction_rules.xml` /
  `backup_rules.xml`.
- iOS: store DB under `getApplicationSupportDirectory()`; mark with
  `NSURLIsExcludedFromBackupKey`.
- Verification logs: retain rolling 90 days (`verificationLogDao.purgeOlderThan(now - 90d)` on app start).

---

## 6. Camera & UX details for the Verify screen

### 6.1 Open camera immediately

- Pre-warm `availableCameras()` + repository pre-load **before** the user
  reaches the screen. Trigger in `home_screen.dart` `onTap` of the verify
  card with `unawaited(ref.read(verifyPrewarmProvider.future))`. Do **not**
  block the route push — just kick off the prewarm.
- `verifyPrewarmProvider`:
  - Calls `availableCameras()` (caches list).
  - Calls `userRepository.activeFlatTemplates()` (decrypts once; passed via
    Riverpod into the controller).
  - Calls `embeddingIsolate.spawn()` (idempotent).
  Total wall-clock budget: < 600 ms on Pixel 6.

### 6.2 Alignment guidance widget

- Centered oval mask + "Look at the camera" copy.
- Ring color: red (no face / poor quality), amber (quality ok, awaiting
  liveness), green (matching).
- Status bar at bottom: `"Hold still"` → `"Blink to verify"` → `"Matching…"` →
  result dialog.

### 6.3 Result handling

- **Granted dialog** with:
  - Big check icon, "Identity Confirmed" title, "<name>" subtitle.
  - TTS speaks `"Identity confirmed, <name>"` once on first show; pause
    further frame processing until dismissed.
  - Auto-dismiss after 4 s OR explicit "Done" button.
- **Denied dialog** with:
  - Best similarity (debug builds only), failure reason, "Try again" CTA.
  - On retry: reset controller state but keep the camera stream alive (no
    bootstrap cost).

### 6.4 Multi-face / no-face / low-light

- Multi-face: red border, "Only one face allowed", do **not** start a verify;
  do not consume a rate-limit slot.
- No face: amber, "Position your face in the oval".
- Low light: amber, "Move to better lighting"; brightness threshold 35 (this
  is below the QualityAssessor default of 45 to avoid over-rejecting).

---

## 7. Fraud-prevention pipeline (concrete additions)

| Attack                       | v1 mitigation                                                                                                                             | Notes                                                                                  |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Photo print                  | Active blink (eye-open prob close→open transition) + mandatory                                                                            | Already implemented                                                                    |
| Video replay                 | Combined: blink **+** mouth-open challenge **+** motion variance check (§7.2)                                                             | Mouth-open is policy-flagged; default off, on for high-security deployments            |
| Static image (held still)    | `replayMotionMaxStdPx` — bbox centroid std across last 1 s must be > a small floor; perfectly static = reject                             | Implement in controller as a 30-frame rolling buffer                                   |
| Screen reflection            | High-saturation + rectangular boundary heuristic via `image` package on the cropped face                                                  | Cheap; runs once per attempt right before embedding                                    |
| Occlusion attack             | §3.6 occlusion gate                                                                                                                       | Reject sunglasses + scarf + hand                                                       |
| Replay with deepfake video   | Out of scope for v1 — document; passive texture liveness + depth-camera optional in v2                                                    | See `10_security.md`                                                                   |

### 7.1 Anti-spoof event log

Every rejected attempt writes a row to `verification_logs` with `outcome =
spoof|denied|rateLimited` and the failure reason. Useful for tuning
thresholds in pilot deployments without exposing PII.

### 7.2 Motion-variance check (cheap)

```
Buffer = ring buffer of last 30 face-bbox centroids (≈ 1 s at 30 fps).
std_x, std_y = stddev(buffer.x), stddev(buffer.y)
if (std_x < replayMotionMaxStdPx && std_y < replayMotionMaxStdPx) {
   /* identical position frame-after-frame ⇒ photo / static screen */
   emit Reason.spoof
}
```

This **must** run before the rate-limited isolate handoff, so a print attack
doesn't burn the embedding budget.

### 7.3 Screen reflection heuristic

On the 112×112 RGB crop, sample 256 random pixels:
- compute mean saturation; if > 0.65 and mean luma > 220 → likely screen.
- approximate edge straightness on the bounding rect: if the cropped face
  detected lies inside a high-contrast rectangular border (top + bottom edge
  std deviation low), reject.

This is heuristic, not infallible; it raises the cost of trivial replay.

### 7.4 Rate limiter

```
rateLimiterProvider:
   key:   "rl:verify"      (also "rl:verify:<userId>" for per-user lockout)
   data:  ring of timestamps in flutter_secure_storage
   check(): purge entries older than rateLimitWindowMs;
           if count >= 5 → return cooldown(now + rateLimitCooldownMs)
   recordFailure() / recordSuccess() {clear}
```

Persist in **secure storage** (not plain `SharedPreferences`) so a tampering
adversary cannot reset by clearing `getApplicationDocumentsDirectory()`. UI
shows `"Too many attempts. Try again in 30 s."`.

---

## 8. Performance plan

| Lever                                                                     | Expected improvement                                                  |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Isolate-pinned TFLite (one isolate, `transferableTypedData`)              | UI thread free during 100–180 ms extract; preview stays ≥ 28 fps     |
| Pre-resize the crop to 112×112 **on caller** before sending to isolate    | Wire payload 37 KB instead of full crop (~150 KB)                     |
| Skip `img.copyResize` per pixel loop where possible (use bilinear `image` package built-in) | Already done in `_imageToInput`; verify XNNPack picks it up   |
| `verifyPrewarmProvider` (camera list + DEK fetch + DB decrypt + isolate spawn) | First-frame visible time drops ~700 → ~300 ms on Pixel 6              |
| Use `ImageFormatGroup.nv21` Android / `bgra8888` iOS, ML Kit `fromBytes`  | No `Bitmap` allocation per frame                                      |
| `QualityAssessor` short-circuits (already does)                            | Saves ~5 ms per failing frame                                         |
| Brightness sample step ≥ 64 (`raw.planes[0]` Y-only)                       | < 0.3 ms per frame                                                    |
| Don't allocate `List<List<List<List<double>>>>` per frame — reuse buffers  | Saves ~6 ms/extract; batch can reuse the 1×112×112×3 nested list      |
| Pure-Dart matcher kept; FFI shim only past 5 000 templates                 | Avoid unnecessary platform code complexity                            |

### 8.1 Targets to enforce in CI (real device)

- Cold start to home screen ≤ 1 800 ms.
- Tap-to-first-frame on `/verify` ≤ 700 ms (Pixel 6 / iPhone 12), ≤ 1 100 ms (Galaxy A21).
- Embedding p95 ≤ 200 ms.
- Cosine search p95 ≤ 8 ms / 1 000 templates.
- End-to-end attempt success path ≤ 5 s; fail path ≤ 3 s.
- 20 verifications heap delta ≤ 320 MB; TFLite interpreter count == 0 after teardown.
- Preview ≥ 28 fps p50.

### 8.2 Battery / thermal

- Stop the camera stream as soon as a granted/denied dialog opens.
- Cap `frameIntervalMs` at 33 (30 fps); the controller drops everything else.
- Keep the screen-on flag scoped to the verify route only.

---

## 9. Architecture-pattern recommendation summary

> **Use Riverpod 2 + Clean Architecture (Lite). Do not introduce Bloc or MVVM
> as a parallel framework.**

Reasoning:

- The codebase already commits to Riverpod (`pubspec.yaml`, `core/di/providers.dart`).
- Bloc adds boilerplate (events + states + transitions per screen) that gives
  no observable benefit over the existing `Notifier<VerificationState>` FSM.
- "MVVM" is conceptually how the controllers are already organized — the
  `VerificationController` is the ViewModel for `VerificationScreen`. We don't
  need a third name for it.
- Modular feature-based: keep everything for verification under
  `lib/features/face_verification/`. Defer multi-feature splits until a second
  feature exists.
- TFLite/MediaPipe: stay on TFLite (mirrors Android, model already validated).

---

## 10. Inline comment / documentation conventions for verification modules

Apply the following comment policies when implementing the new files
described above. (Don't add these to existing files now; the user explicitly
asked us not to modify code yet — but capture the policy here so the
implementation PR follows it.)

1. **File header**: 2–4 lines stating the responsibility and which Android
   class it ports from (e.g. `// Ports VerificationScreen.kt — controller only`).
2. **Class doc**: one-paragraph contract: invariants, threading expectation,
   provider lifetime.
3. **Threshold use sites**: when a numeric constant is referenced, comment
   with the **why**, not the **what**. e.g.
   `// Two consecutive null eye probabilities — ML Kit returns null when` +
   `// classifier confidence is low; we treat persistent null as occlusion.`
4. **Isolate boundary**: every `SendPort.send(...)` and corresponding receive
   gets a comment naming the wire schema (the ordering/identity of the list).
5. **Crypto sites**: every `encrypt`/`decrypt` call site is annotated with
   what is in the plaintext (i.e. encoded `List<Float32List>`), so a future
   reader does not introduce another caller with a different layout.
6. **Logging sites**: every `_log.warning`/`severe` is annotated stating
   which fields it must NOT log (embedding contents, names). This is
   auditable in code review.
7. **No doc-strings on getters / `copyWith`** — they self-document.
8. **Riverpod providers**: 1-line comment with lifetime (`autoDispose` /
   `keepAlive`) and consumers, so dependency cycles are easy to spot.

---

## 11. Risk register (verification-flow specific)

| Risk                                                                                                     | Mitigation                                                                                            |
| -------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| ML Kit returns no contours on cheap front cameras → false occlusion rejects                              | Fall back to landmark-count heuristic; lower min from 8 to 6 for low-end builds via remote config     |
| Isolate spawn timeout on first-launch low-end Android                                                    | 600 ms hard timeout → fall back to inline TFLite (slower, but functional)                             |
| TTS unavailable (no engine installed)                                                                    | Visible banner is canonical; TTS is best-effort; never throw on speak failures                        |
| Drift schema bump rolled out without migration                                                           | Parity test reads a packaged v1 DB fixture in CI                                                      |
| User rapidly toggles screen → controller re-built, isolate re-spawned                                    | Make `embeddingIsolateProvider` keepAlive; controller only registers a request port                  |
| GPU delegate driver bug                                                                                  | Probe with a 1×1 dummy run during `EmbeddingIsolate.spawn`; on failure log + use CPU                  |
| Match threshold (0.75) tuned for Android camera; iOS BGRA path may shift distribution slightly           | `embedding_parity_test.dart` checks Android-recorded frames vs Flutter pipeline embedding cosine ≥ 0.95 |
| Verification log table grows unbounded                                                                   | 90-day retention purge on app start                                                                   |
| Rate-limit data lost if user reinstalls (user clears app data)                                           | Acceptable for local-only flow; an attacker willing to reinstall for 5 attempts is out of scope       |

---

## 12. Implementation order (suggested PR slicing)

1. **Schema bump v2** + parity test (DB only, no UI). Reviewable in isolation.
2. **OcclusionDetector + thresholds.dart additions** + unit tests.
3. **EmbeddingIsolate** + integration test that proves UI thread is free.
4. **VerifyUser use case** + unit tests against fakes (no UI yet).
5. **VerificationScreen UI** wired to existing controller (replace stub).
6. **TTS announcer** + RateLimiter + verification log writes.
7. **Manage Users screen UI** + UserDetailSheet + last-verified column.
8. **Anti-spoof heuristics** (motion variance, screen reflection).
9. **Performance hardening pass** (buffer reuse, prewarm).
10. **CI gates** (golden tests, perf budgets, parity test fixtures).

Each PR is independently shippable and revertable.

---

## 13. What explicitly stays out of v1

- 68-point iBUG landmarks (deferred — see §3.7).
- Passive texture liveness (depth-camera / texture model).
- FFI matcher (kept until N > 5 000).
- Server-side verification fallback.
- Multi-tenant key-rotation flow (single DEK is acceptable; document key
  rotation procedure in `10_security.md` only).
- Cross-device template sync.

These are intentional non-goals so v1 can ship with a tight blast radius.
