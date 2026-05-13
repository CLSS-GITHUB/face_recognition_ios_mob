# PAD Checkpoint Procurement & Rollout Runbook

**Owner:** Verification platform
**Status:** Draft — pending checkpoint procurement
**Audience:** Whoever is dropping the first real PAD model into the bundle
**Cross-refs:**
- `lib/core/isolates/pad_isolate.dart` — the runtime that will load this checkpoint
- `lib/core/di/providers.dart` — `kPadEnabled`, `kPadPolicy`, `padClassifierProvider`
- `docs/verification/ultra_fast_verification_analysis.md` §9.4 — security-model rationale
- `docs/NATIVE_VS_FLUTTER_ANALYSIS.md` §9 (Phase B) — the plan this runbook implements

---

## 1. Scope

This document covers the **B1** item of the Phase B anti-spoof
hardening plan: shipping a calibrated Presentation Attack Detection
(PAD) checkpoint that the existing scaffold (`PadIsolate` +
`padClassifierProvider`) can load. The runtime side is already
in place — this runbook describes the **manual** decisions
(licensing, provenance, calibration) that have to be made outside
the build.

It does **not** cover:
- B2 (flip `PadPolicy` from `shadow` to `enforce`) — that's a
  follow-on once shadow data converges. See §6.
- B3 (Gabor texture gate) — shipped independently; see
  `lib/services/gabor_texture_detector.dart`.

---

## 2. Reference checkpoint: Silent-Face-Anti-Spoofing

The recommended starting point — selected in the report consult — is
the Silent-Face MiniFASNet family from
[`github.com/minivision-ai/Silent-Face-Anti-Spoofing`](https://github.com/minivision-ai/Silent-Face-Anti-Spoofing).

**Why this one:**
- License: Apache 2.0 (compatible with our distribution).
- Published model with public training data description (CASIA-SURF,
  publicly described methodology).
- The exact model the PadIsolate scaffold's defaults are tuned for:
  - `PadModelKind.silentFaceThree` (3-class softmax: print, real, replay)
  - `PadNormalization.imagenet` (per-channel ImageNet mean/std)
  - 80×80 RGB input (PadIsolate's bilinear resize handles this from the
    canonical 112×112 RGB crop).
- Small footprint: ~2 MB INT8 / ~6 MB FP32, comparable to the
  embedding model.
- MiniFASNetV1SE and MiniFASNetV2 are both supported. Pick V2 if you
  have a choice — it scored better in the upstream evaluation.

**Outputs of MiniFASNet (Silent-Face training convention):**
- Order: `(spoof_print, real, spoof_replay)`.
- After softmax, `p[1]` is the real probability; spoof = `1 - p[1]`.
- This is exactly what `reduceToSpoofScore` already implements for
  `PadModelKind.silentFaceThree`.

If you can't use this checkpoint, the supported alternatives are:
- A single-scalar sigmoid head (`PadModelKind.singleSigmoidScalar`)
- A two-class softmax `(real, spoof)` head (`PadModelKind.binarySoftmax`)

The PadIsolate probes the actual output shape at spawn and rejects
mismatch with a clear `_PadInitFailure` — getting the polarity wrong
turns a deny-gate into an allow-gate, so the scaffold refuses to run
unless the configured `PadModelKind` matches the model.

---

## 3. Procurement checklist

Run through this once when adding the checkpoint. Tick each item
in the PR description so reviewers can audit the provenance.

- [ ] **Source URL recorded.** Note the exact commit hash and the
      release tag (e.g.
      `github.com/minivision-ai/Silent-Face-Anti-Spoofing@<sha>`)
      in the commit message.
- [ ] **License file captured.** Save the upstream `LICENSE` file
      to `assets/models/pad_LICENSE.txt`. Apache 2.0 requires
      including this notice with redistribution.
- [ ] **Training-data ancestry noted.** Capture which dataset the
      checkpoint was trained on (CASIA-SURF / CelebA-Spoof / etc.)
      and any usage restrictions on that dataset. Skin-tone
      coverage and lighting diversity matter for our deployment
      population — flag the gap if obvious.
- [ ] **Hash recorded.** Compute the SHA-256 of the
      `.tflite` file and add it as a constant in
      `PadIsolate._expectedSha256` (placeholder TODO already in
      place). This makes "wrong file dropped in `assets/`" a
      build-time test failure instead of a silent score drift.
- [ ] **Output shape verified.** Run `PadIsolate.spawn` with
      `PadModelKind.silentFaceThree` against the bundled file in
      a smoke test. The init-failure message tells you immediately
      if the output shape is wrong — no field debugging.
- [ ] **Input dimension recorded.** Note the actual `inputSize`
      the isolate probed (`modelLabel` surfaces this on
      `/debug/health`). Save it to the rollout plan for
      latency-budget planning.

---

## 4. Conversion (PyTorch → TFLite)

The upstream repo ships PyTorch / Caffe checkpoints. Conversion
path:

1. PyTorch checkpoint → ONNX via `torch.onnx.export` with
   `opset_version=13`, fixed input shape `[1, 3, 80, 80]`.
2. ONNX → TFLite via the `onnx-tf` → SavedModel → TFLiteConverter
   pipeline, OR directly with `onnx2tf` (preferred — fewer
   dimension-permutation foot-guns).
3. **Do not** apply post-training INT8 quantization without
   re-running the validation. INT8 PAD has shown ≥10% spoof-recall
   regressions on Silent-Face in upstream evaluations; the TFLite
   delegate chain already gives us most of the inference speed-up
   without precision loss.

Output assertions before bundling:
- Input tensor: `[1, 80, 80, 3]`, `float32`.
- Output tensor: `[1, 3]`, `float32`.
- A standard test image (a Lena thumbnail or similar — anything
  fixed across runs) produces a stable, non-degenerate score.
  Capture the expected score in the smoke test below.

---

## 5. Bundling & wiring

Once you have a vetted `.tflite` file:

1. Drop it at `assets/models/pad.tflite`. No `pubspec.yaml` change
   needed — `assets/models/` is already declared as an asset
   directory.
2. Update `PadIsolate._expectedSha256` with the actual hash (and
   wire the hash check into `spawn`).
3. Build with the runtime flags:
   ```
   flutter build apk \
     --dart-define=PAD_ENABLED=true \
     --dart-define=PAD_POLICY=shadow \
     --dart-define=PAD_MODEL_KIND=silentFaceThree \
     --dart-define=PAD_PIXEL_NORM=imagenet
   ```
   These match the defaults in `providers.dart`; the flags exist
   so a deployment with a different model contract can override
   without code edits.
4. Cold-launch the app and visit `/debug/health`. You should see:
   - `pad: tflite(80x80x3 → [1,3], kind=silentFaceThree, norm=imagenet)`
     (or whatever your actual input size resolves to)
   - The latency tracker logging a `padIsolate.spawn` event with
     a reasonable duration (target ≤ 80 ms on Pixel 6).

If the label says `noop` or `unavailable`, the checkpoint isn't
being loaded — check the logcat for `PadIsolate` warnings.

---

## 6. Calibration & the shadow → enforce flip (B2)

`PAD_POLICY=shadow` is **mandatory** for the initial rollout.
Reasons documented in `providers.dart` `PadPolicy` doc; summary:
the `padSpoofThreshold` default is `0.5`, an unvetted placeholder.
Enforcing on day one means we either over-reject real users
(`FRR` regression) or under-reject attacks (no security benefit).

The calibration loop:

1. **Ship in shadow** for ≥ 2 weeks. The pipeline runs PAD on
   every grant attempt, writes the score to
   `verification_logs.pad_score`, but does **not** short-circuit
   the grant. Real users get in normally; replay-attack attempts
   are scored but not stopped at the PAD gate.
2. **Export the logs.** Use `/debug/health` → CSV export
   (F-10 export commit). Pull at least 1000 rows per planned
   deployment population — different lighting, different devices,
   ideally some adversarial replay attempts seeded by the
   security team.
3. **Run the calibration helper.** `lib/core/diagnostics/pad_calibration.dart`
   takes a list of `(padScore, outcome)` and emits a threshold
   sweep with FRR/FAR for each candidate cutoff. Pick the threshold
   that hits the target operating point — typically FRR ≤ 1% on
   real users with FAR ≤ 5% on attempted attacks.
4. **Update `FaceThresholds.padSpoofThreshold`.** Bump the
   constant, ship a release with the new value still in
   `PAD_POLICY=shadow`, confirm a week's worth of new data still
   matches the calibration prediction.
5. **Flip the policy.** Build with `PAD_POLICY=enforce` and
   confirm `/debug/health` reports the change. The verify
   controller's `_denyForSpoof` path now fires on any
   `padScore > threshold` grant.

**Never** flip enforce without running the loop. The
`shadow` mode exists exactly so the security team can land a
checkpoint without a user-experience regression while the data
flows.

---

## 7. Rollback

If shadow-mode data shows the bundled checkpoint mis-calibrated
beyond what threshold tuning can fix (e.g., systematic skin-tone
bias):

1. Build with `--dart-define=PAD_ENABLED=false`. The
   `padClassifierProvider` resolves to `NoOpPadClassifier`
   immediately on the next cold launch.
2. Field operators reading `/debug/health` see `pad: noop` —
   the signal that the security model has reverted to pre-PAD
   stack (motion + screen-reflection + Gabor + active
   challenge).
3. Open a follow-up to source a better checkpoint. Do **not**
   ship `PAD_POLICY=enforce` again until step 1 of this
   document's calibration loop has been re-run on the new
   checkpoint.

The `NoOpPadClassifier` fallback is the same path that runs on
devices where `Isolate.spawn` itself fails — so the security
floor when PAD is disabled is identical to the floor before B1
existed.

---

## 8. Open questions for the procurement owner

- **Which deployment population first?** Calibration in a low-
  diversity population produces a threshold that may over-reject
  in production. Start somewhere representative.
- **Adversarial test set.** Do we have access to a vetted attack
  corpus (screen replays, print attacks, mask attacks) to validate
  the FAR side of the calibration curve? Without it, `FAR` numbers
  are theoretical.
- **Re-calibration cadence.** Plan for re-calibration every 6-12
  months as the user population drifts. Add to the deployment
  runbook.

---

*Status checklist:*
- [x] Runbook drafted
- [ ] Reference checkpoint procured
- [ ] License + provenance audit complete
- [ ] SHA-256 hash pinned in code
- [ ] Smoke test passing on `/debug/health`
- [ ] Shadow-mode shipped to staging
- [ ] Calibration loop run on ≥ 1000 rows
- [ ] Threshold updated in `FaceThresholds`
- [ ] Enforce mode shipped
