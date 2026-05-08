# 09 — Performance Optimization

## 9.1 Android baseline budgets (carry into Flutter)

From `application_performance.md` and direct source review:

| Operation | Android target | Flutter target (same hardware class) |
|---|---|---|
| Face detection (single frame) | 30–50 ms (ML Kit fast mode) | 35–55 ms (≤ 5 ms plugin overhead) |
| Quality assessment | 10–20 ms | 5–15 ms (pure Dart) |
| Embedding extraction (TFLite) | 80–150 ms (CPU, XNNPack, 4 threads) | 100–180 ms; profile w/ GPU delegate |
| Single liveness step | 1–3 s wall clock (user-bound) | identical |
| Full 5-step liveness | 15–30 s | identical |
| DB lookup of all users | 5–10 ms (≤ 10 users) | 3–8 ms (Drift) |
| Cosine similarity match (10 templates) | < 1 ms (NEON) | 1–3 ms (Dart Float32List), < 1 ms (FFI) |
| Total enrollment | 20–60 s | identical |
| Total verification | 2–10 s | identical |
| Steady-state memory | 200–300 MB | 220–320 MB (Flutter engine adds ~20 MB) |

If any number drifts > 1.5× the Android baseline on the same device, treat it as a regression and apply the playbooks below.

## 9.2 Frame pipeline — the highest-leverage path

Each frame goes through:

```
CameraImage  →  Bitmap/RGBA  →  ML Kit  →  FaceData  →  QualityAssessor
                                                    │
                                  (if all liveness steps complete)
                                                    ▼
                                    Crop face (25% margin)
                                                    │
                                                    ▼
                                  Resize 112×112 + normalize
                                                    │
                                                    ▼
                                          TFLite inference
                                                    │
                                                    ▼
                                        L2 normalize → 192-D
```

Key optimizations, in priority order:

### 9.2.1 Skip frames while busy (back-pressure)

Reproduce CameraX's `STRATEGY_KEEP_ONLY_LATEST`:

```dart
bool _busy = false;
void _onCameraImage(CameraImage img) {
  if (_busy) return;
  _busy = true;
  Future.microtask(() async {
    try { await _processFrame(img); } finally { _busy = false; }
  });
}
```

Without this, the `camera` plugin will queue frames faster than ML Kit can consume them, leaking memory and causing UI jank.

### 9.2.2 Avoid full-bitmap allocation per frame

The Android side allocates a fresh `Bitmap` from `ImageProxy` on every frame — `application_performance.md` flags this as a known bottleneck. In Flutter:

- **For ML Kit:** pass `CameraImage` planes directly via `InputImage.fromBytes(bytes: planeBytes, metadata: ...)`. Do **not** convert to `dart:ui.Image` first. The `google_mlkit_face_detection` README has the exact YUV plane wiring.
- **For TFLite:** convert YUV → RGB only for the cropped face region (typically a 200×200 px sub-rectangle), not the full frame. Implement once in `core/utils/image_processing.dart::yuvCropToRgb`.

### 9.2.3 Run TFLite off the UI isolate

Inference is 80–180 ms — five frames at 30 fps. Run it in a dedicated isolate and pass results back as a `Float32List` (transferable on Dart 3+):

```dart
final _inferenceIsolate = await _spawnInferenceIsolate('assets/models/mobile_facenet.tflite');

Future<Float32List> extract(Float32List inputTensor) async {
  return _inferenceIsolate.send(inputTensor);
}
```

Use `Isolate.run` for one-shot calls if a long-lived isolate is over-engineering for v1.

### 9.2.4 GPU / NNAPI delegate

`tflite_flutter` supports `GpuDelegateV2` on Android and `MetalDelegate` on iOS. Profile both:

```dart
final options = InterpreterOptions()
  ..threads = 4;
if (Platform.isAndroid) options.addDelegate(GpuDelegateV2());
if (Platform.isIOS)     options.addDelegate(GpuDelegate());
```

Expect 1.5–3× speedup on flagship devices and ~equal on low-end. Fall back to CPU + XNNPack on delegate init failure (the plugin throws on incompatible OS versions).

### 9.2.5 Quality metrics pixel sampling

The Android side samples every 5th pixel for brightness; replicate exactly. In Dart:

```dart
double averageLuminance(img.Image image, Rect roi, {int step = 5}) {
  var sum = 0.0; var count = 0;
  for (var y = roi.top.toInt(); y < roi.bottom.toInt(); y += step) {
    for (var x = roi.left.toInt(); x < roi.right.toInt(); x += step) {
      final p = image.getPixel(x, y);
      sum += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      count++;
    }
  }
  return count == 0 ? 0 : sum / count;
}
```

`image.getPixel` is slow per call. For hot paths, convert to `image.toUint8List()` and index manually with row stride.

## 9.3 Matching: pure Dart vs FFI

For `N ≤ 1 000` 192-D templates:

```dart
double cosine(Float32List a, Float32List b) {
  var s = 0.0;
  for (var i = 0; i < 192; i++) s += a[i] * b[i];
  return s;        // both vectors are L2-normalized
}

(int idx, double sim) findBestMatch(Float32List probe, Float32List flat, int n) {
  var best = -1; var bestSim = -2.0;
  for (var i = 0; i < n; i++) {
    final off = i * 192;
    var s = 0.0;
    for (var j = 0; j < 192; j++) s += probe[j] * flat[off + j];
    if (s > bestSim) { bestSim = s; best = i; }
  }
  return (best, bestSim);
}
```

Benchmark on a Pixel 6: ~0.6 ms for 100 templates, ~6 ms for 1 000 templates. Acceptable.

If a customer ever crosses 5 000 templates, switch to FFI:

```dart
typedef _FindBestC = ffi.Int32 Function(
  ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>, ffi.Int32, ffi.Int32);
typedef FindBestDart = int Function(
  ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>, int, int);
final FindBestDart findBestNative =
  ffi.DynamicLibrary.open(_libName)
   .lookupFunction<_FindBestC, FindBestDart>('findBestMatchNative');
```

The existing `face_matcher.cpp` is ABI-compatible after stripping the `JNI*` parameters — keep a small `face_matcher_c.cpp` shim so both Android (JNI) and FFI versions can coexist.

## 9.4 Memory management

- **TFLite Interpreter** must be `close()`d when its provider disposes. Riverpod `ref.onDispose` handles this automatically.
- **`img.Image` instances** are heap-allocated. Don't hold references in state — only the resulting embedding (`Float32List(192)` = 768 bytes).
- **Camera frames** must not be retained past `_onCameraImage` return, or the plugin will block the producer.

## 9.5 Startup performance

- Lazy-load the TFLite interpreter on first `verify`/`enroll` route entry, not at app launch. This trims ~150 ms from cold-start TTFB.
- Pre-fetch users for verification via a `FutureProvider` triggered on screen entry, not on app launch.
- Don't bundle dev-only assets in release builds.

## 9.6 Histogram equalization & alignment

The Android `ImageQualityEngine.enhance()` rotates by eye-line angle and applies histogram equalization if brightness < 100. Both are CPU-heavy in pure Dart:

- **Rotation by inter-eye angle:** use `dart:ui` `Image` + `Canvas.rotate` once per crop; convert back to `Float32List` for the tensor. ~3–5 ms.
- **Histogram equalization:** `image` package's `equalizeHistogram` is ~15–25 ms on a 112×112 crop. Acceptable.

Apply enhancement **only** when brightness < 100 (matching Android's threshold). Otherwise skip.

## 9.7 The "Fast Path" decision

The Android source has a logic flaw documented in `application_performance.md`:

> `FaceRecognizer` previously had an asymmetry where the "Fast Path" (verification) skipped face alignment, while "Enrollment" included it. This caused lower similarity scores for tilted faces.

`VerificationScreen.kt` already calls `extractEmbedding(..., fastPath = false)` to compensate. **For the Flutter port, drop the `fastPath` parameter altogether**. Always align + enhance — it's < 30 ms total and ensures enrollment/verification embeddings come from the same distribution. If profiling later shows the alignment step needs short-circuiting, gate it on `face.headEulerZ.abs() < 3` (already-vertical face).

## 9.8 Profiling checklist (run before claiming "done")

- [ ] DevTools timeline shows < 50 ms for the ML Kit + TFLite phases combined on a Pixel 5 / iPhone 12 class device.
- [ ] No frame drops in the camera preview during steady state (60 fps observed on Android).
- [ ] Memory plateaus < 320 MB after 20 consecutive verifications.
- [ ] No `image.Image` allocations leak across frames (check the GC chart).
- [ ] First verification after enroll shows < 2 s end-to-end on warm cache.

If any line fails, do not consider the migration acceptance-tested.
