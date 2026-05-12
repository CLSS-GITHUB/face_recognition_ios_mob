import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'
    show FaceLandmarkType;
import 'package:logging/logging.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../../../../core/constants/thresholds.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/platform/rate_limiter.dart';
import '../../../../core/utils/blur_metric.dart';
import '../../../../core/utils/frame_preparation.dart';
import '../../domain/entities/face_data.dart';
import '../../domain/entities/liveness_step.dart';
import '../../domain/entities/quality_result.dart';
import '../../domain/entities/user.dart';
import '../../../../services/device_motion_detector.dart';
import '../../../../services/motion_variance_detector.dart';
import '../../../../services/screen_reflection_detector.dart';
import '../../domain/entities/verification_failure.dart';
import '../../domain/entities/verification_log.dart';
import '../../domain/entities/verify_decision.dart';
import '../../domain/repositories/user_repository.dart';

class VerificationState {
  const VerificationState({
    required this.status,
    required this.quality,
    required this.faces,
    required this.frameSize,
    required this.isVerifying,
    required this.matchedUser,
    required this.showResult,
    required this.challenge,
    required this.livenessPassed,
    required this.isBlinking,
    required this.eyeOpenSeen,
    required this.flat,
    required this.isReady,
    required this.bestSimilarity,
    required this.cooldownUntil,
  });

  const VerificationState.initial({
    this.challenge = LivenessStep.blink,
  })  : status = 'Scanning face...',
        quality = null,
        faces = const [],
        frameSize = Size.zero,
        isVerifying = false,
        matchedUser = null,
        showResult = false,
        livenessPassed = false,
        isBlinking = false,
        eyeOpenSeen = false,
        flat = null,
        isReady = false,
        bestSimilarity = 0,
        cooldownUntil = null;

  final String status;
  final QualityResult? quality;
  final List<FaceData> faces;
  final Size frameSize;
  final bool isVerifying;
  final User? matchedUser;
  final bool showResult;

  /// Liveness challenge the user must perform this attempt. Picked once
  /// per attempt from [verifyChallengeOptions] using `Random.secure` —
  /// a single replay video can satisfy at most one option, so a 4-way
  /// pick forces the attacker to record (and successfully present) the
  /// right behaviour at the right moment.
  final LivenessStep challenge;

  /// True once the active [challenge] has been performed. Replaces the
  /// previous `blinkDetected` flag, which only described one of four
  /// possible challenges.
  final bool livenessPassed;

  /// Transient state used by the BLINK challenge handler only. Other
  /// challenges keep their progress on the controller's private fields.
  final bool isBlinking;
  final bool eyeOpenSeen;
  final FlatTemplates? flat;
  final bool isReady;
  final double bestSimilarity;

  /// When non-null and `> now()`, the rate limiter is forcing a cooldown
  /// and the controller short-circuits each frame. Set after the
  /// `rateLimitMaxFailures`th denial; cleared on dismissResult.
  final DateTime? cooldownUntil;

  VerificationState copyWith({
    String? status,
    QualityResult? quality,
    bool clearQuality = false,
    List<FaceData>? faces,
    Size? frameSize,
    bool? isVerifying,
    User? matchedUser,
    bool clearMatchedUser = false,
    bool? showResult,
    LivenessStep? challenge,
    bool? livenessPassed,
    bool? isBlinking,
    bool? eyeOpenSeen,
    FlatTemplates? flat,
    bool? isReady,
    double? bestSimilarity,
    DateTime? cooldownUntil,
    bool clearCooldown = false,
  }) {
    return VerificationState(
      status: status ?? this.status,
      quality: clearQuality ? null : (quality ?? this.quality),
      faces: faces ?? this.faces,
      frameSize: frameSize ?? this.frameSize,
      isVerifying: isVerifying ?? this.isVerifying,
      matchedUser:
          clearMatchedUser ? null : (matchedUser ?? this.matchedUser),
      showResult: showResult ?? this.showResult,
      challenge: challenge ?? this.challenge,
      livenessPassed: livenessPassed ?? this.livenessPassed,
      isBlinking: isBlinking ?? this.isBlinking,
      eyeOpenSeen: eyeOpenSeen ?? this.eyeOpenSeen,
      flat: flat ?? this.flat,
      isReady: isReady ?? this.isReady,
      bestSimilarity: bestSimilarity ?? this.bestSimilarity,
      cooldownUntil:
          clearCooldown ? null : (cooldownUntil ?? this.cooldownUntil),
    );
  }
}

class VerificationController extends AutoDisposeNotifier<VerificationState> {
  static final Logger _log = Logger('VerificationController');

  bool _disposed = false;

  /// Anti-spoof: tracks face-bbox centroid over the last ~1s. A
  /// frame-locked face means a printed photo / static screen — see §7.2.
  final MotionVarianceDetector _motion = MotionVarianceDetector();

  /// Anti-spoof: tracks device-accelerometer magnitude over the last ~1s.
  /// A phone on a tripod showing a recorded video passes face-bbox
  /// motion checks (the face *inside* the video moves) but reads near-
  /// zero variance here — that's the signal we deny on.
  final DeviceMotionDetector _deviceMotion = DeviceMotionDetector();

  /// Subscription to the accelerometer stream, cancelled on dispose
  /// so we don't leak between Verify Identity screen entries.
  StreamSubscription<AccelerometerEvent>? _accelSub;

  /// Anti-spoof: cheap saturation+luma heuristic on the 112×112 RGB crop
  /// — phone-on-phone replay produces unnaturally vivid + bright pixels.
  /// Stateless; see §7.3.
  static const _screenReflection = ScreenReflectionDetector();

  /// Restarted on every frame; if it fires, the camera stream stalled
  /// (architecture §3.2 step 2 / §3.4 frameStaleMs).
  Timer? _staleFrameWatchdog;

  /// Cryptographically-strong RNG used to pick the per-attempt
  /// liveness challenge. A predictable RNG would let an attacker
  /// pre-record a clip matching the next pick.
  final Random _challengeRng = Random.secure();

  /// Transient state for the MOUTH_OPEN challenge: the mouth was
  /// observed open (ratio > mouthOpenEnter); now waiting for it to
  /// close (ratio < mouthCloseExit) before advancing.
  bool _mouthOpened = false;

  /// Transient state for TURN_LEFT / TURN_RIGHT challenges: the
  /// required yaw peak was observed; now waiting for the head to
  /// return near centre before advancing into the match phase.
  bool _turnReached = false;

  /// O-5: speculative pre-extract cache. During liveness we run a
  /// best-effort prepare + extract on stable good frames so that when
  /// the challenge finally passes, the match step has a probe in hand
  /// and can skip the ~45 ms isolate round-trip. Single-shot: consumed
  /// (and nulled) by `_runMatch` on the next match.
  ///
  /// Security: the same defense-in-depth probe-zeroing that VerifyUser
  /// applies on its `finally` block runs whether the embedding came
  /// from this cache or from the slow-path extract. The cache is also
  /// cleared on every challenge-progress reset (replay attempt, stale
  /// frame, dialog dismissal) so a stale probe never crosses
  /// attempt boundaries.
  ({Float32List embedding, DateTime at})? _speculativeProbe;

  /// Re-entrancy guard for [_maybeSpeculate]. The embedding isolate is
  /// single-flight (queue length 1); if a speculation is in flight, we
  /// must not kick off another one — and if `_runMatch` raced ahead and
  /// is about to use the isolate, the speculation we'd start would
  /// throw `EmbeddingBusyError`. Either way: skip.
  bool _inSpeculation = false;

  /// Completer signalled when the current speculation finishes. Lets
  /// `_runMatch` `await` the in-flight speculation instead of racing it
  /// — without this, a "user finishes liveness just as speculation
  /// dispatched to the isolate" sequence makes `_runMatch`'s slow-path
  /// `prepare` throw `EmbeddingBusyError`, which used to surface as a
  /// misleading "Frame format unsupported" status. Cleared at the end
  /// of each speculation in `_maybeSpeculate`'s finally block.
  Completer<void>? _speculationCompleter;

  /// F-4: revision of the active user bank at the moment of the most
  /// recent successful `_warmTemplates`. `dismissResult` compares this
  /// against the current `userBankRevisionProvider` value and skips the
  /// re-warm when they match — the bank cannot mutate while the result
  /// dialog is up (the dialog is modal), so the common case is "no
  /// mutation, no re-decrypt needed". Starts at -1 so the very first
  /// warm always runs.
  int _lastWarmedRevision = -1;

  @override
  VerificationState build() {
    ref.onDispose(() {
      _disposed = true;
      _staleFrameWatchdog?.cancel();
      _staleFrameWatchdog = null;
      _accelSub?.cancel();
      _accelSub = null;
      _clearSpeculativeProbe();
    });
    // Subscribe to the accelerometer at ~50 Hz so a 50-sample ring
    // buffer covers ~1 second of device motion. Errors on the stream
    // (no IMU, transient driver failure) silently leave the buffer
    // empty — isStatic() then never fires, which is the conservative
    // default. We don't want a missing sensor to *cause* a denial.
    try {
      _accelSub = accelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: 20),
      ).listen(
        (event) {
          if (_disposed) return;
          _deviceMotion.record(event.x, event.y, event.z);
        },
        onError: (Object e, StackTrace st) {
          _log.warning('Accelerometer stream error', e, st);
        },
      );
    } catch (e, st) {
      // Some platforms / emulators throw on the call itself. Same
      // "fail open" behaviour as a stream error.
      _log.warning('Failed to subscribe to accelerometer stream', e, st);
    }
    Future.microtask(_warmTemplates);
    return VerificationState.initial(challenge: _pickChallenge());
  }

  /// Uniformly samples one challenge from [verifyChallengeOptions]
  /// using `Random.secure`. Called on screen entry and after every
  /// result dismissal so a replay attacker cannot anticipate the next
  /// pick from prior screens.
  LivenessStep _pickChallenge() {
    return verifyChallengeOptions[
      _challengeRng.nextInt(verifyChallengeOptions.length)
    ];
  }

  /// Restarts the stale-frame timer. Called at the head of every
  /// `processFrame` so a stuck stream eventually surfaces a soft warning
  /// without taking down the screen.
  void _bumpStaleFrameWatchdog() {
    _staleFrameWatchdog?.cancel();
    _staleFrameWatchdog = Timer(
      const Duration(milliseconds: FaceThresholds.frameStaleMs),
      _onStaleFrame,
    );
  }

  void _onStaleFrame() {
    if (_disposed) return;
    // Don't trample a result dialog or an in-flight verify.
    if (state.showResult || state.isVerifying) return;
    _log.warning('Camera frame stalled for '
        '${FaceThresholds.frameStaleMs} ms — soft reset.');
    _motion.reset();
    _deviceMotion.reset();
    _resetChallengeProgress();
    _clearSpeculativeProbe();
    state = state.copyWith(
      livenessPassed: false,
      isBlinking: false,
      eyeOpenSeen: false,
      faces: const [],
      clearQuality: true,
      status: 'Camera stalled — moving back to scan.',
    );
  }

  /// Clear controller-side challenge progress (mouth + turn). The
  /// blink-side transient state lives in [VerificationState] and is
  /// reset there by the caller in the same `copyWith`.
  void _resetChallengeProgress() {
    _mouthOpened = false;
    _turnReached = false;
  }

  Future<void> _warmTemplates() async {
    try {
      // F-4: snapshot the revision BEFORE the decrypt so an
      // interleaved mutation that lands during decrypt still triggers a
      // future re-warm (we'd see `current > _lastWarmedRevision` on the
      // next dismissResult check).
      final revision = ref.read(userBankRevisionProvider);
      final flat =
          await ref.read(userRepositoryProvider).activeFlatTemplates();
      if (_disposed) return;
      _lastWarmedRevision = revision;
      state = state.copyWith(flat: flat, isReady: true);
      _log.fine('Pre-warmed ${flat.count} templates from '
          '${flat.uniqueUserCount} unique users (rev=$revision)');
    } catch (e, st) {
      _log.severe('Failed to pre-warm templates', e, st);
      state = state.copyWith(
        isReady: true,
        status: 'Database unavailable',
        flat: FlatTemplates.empty,
      );
    }
  }

  /// Public re-warm hook. The verify screen invokes this whenever the
  /// user lands back on it from enrollment / management routes so a
  /// newly enrolled or deleted user shows up immediately — otherwise the
  /// flat bank set on `build()` is stale until the controller auto-
  /// disposes.
  Future<void> refreshTemplates() async {
    if (_disposed) return;
    await _warmTemplates();
  }

  Future<void> processFrame(CameraImage raw, InputImage forMlKit) async {
    // Restart the stale-frame timer regardless of where this frame
    // short-circuits below — what we care about is "frames are arriving",
    // not "frames are being fully processed".
    _bumpStaleFrameWatchdog();

    // While a result dialog is up, every subsequent frame would otherwise
    // fall straight through to `_runMatch` (blinkDetected is still true and
    // isVerifying has flipped back to false). The dialog stays open until
    // `dismissResult` is called, so until then we stop doing work.
    if (state.isVerifying || !state.isReady || state.showResult) return;

    // Rate-limit cooldown: skip the entire pipeline (no detection, no ML).
    final cd = state.cooldownUntil;
    if (cd != null && DateTime.now().isBefore(cd)) {
      final secs = cd.difference(DateTime.now()).inSeconds + 1;
      state = state.copyWith(status: 'Too many attempts. Try again in ${secs}s.');
      return;
    }

    final detector = ref.read(faceDetectionServiceProvider);
    // ML Kit's detector occasionally hangs or throws on a malformed
    // frame (driver glitches, rotation/format mismatches after a hot
    // restart). Wrap with a hard timeout + catch so a single bad
    // frame degrades to "no face detected" instead of bubbling into
    // the camera plugin's microtask and silently freezing the FSM
    // (matches the enrollment controller's guard).
    List<FaceData> faces;
    try {
      faces = await detector.detect(forMlKit).timeout(
        const Duration(seconds: 3),
        onTimeout: () => const <FaceData>[],
      );
    } catch (e, st) {
      _log.warning('Face detection threw — treating as no face', e, st);
      faces = const <FaceData>[];
    }
    if (_disposed) return;
    final rawFrameSize = forMlKit.metadata?.size ?? Size.zero;
    // ML Kit returns bbox in rotated coords; match frame dims so centering
    // checks compare like-for-like. (Same fix as EnrollmentController.)
    final rotation = forMlKit.metadata?.rotation;
    final isQuarterRotated = rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final frameSize = isQuarterRotated
        ? Size(rawFrameSize.height, rawFrameSize.width)
        : rawFrameSize;

    if (faces.length > 1) {
      state = state.copyWith(
        faces: faces,
        frameSize: frameSize,
        quality:
            const QualityResult.failed(['Multiple faces detected.']),
      );
      return;
    }
    if (faces.isEmpty) {
      state = state.copyWith(
        faces: faces,
        frameSize: frameSize,
        quality: const QualityResult.failed(['No face detected']),
      );
      return;
    }

    final face = faces.first;
    // Brightness is only consumed by the quality assessor, which only
    // runs when we have exactly one detected face. Computing it before
    // the multi-face / no-face short-circuits above wasted ~30k luma
    // samples/sec on frames that would never use them.
    final brightness = _approximateBrightness(raw);

    // Anti-spoof bookkeeping: feed every well-detected single face's bbox
    // centroid into the motion-variance ring buffer so we can decide
    // whether the frame is "alive" before we burn the embedding budget
    // (architecture §7.2). The detector is cheap and stateful — even
    // pre-blink frames count toward the rolling window so by the time
    // we reach the match path we already have a verdict.
    _motion.recordCentroid(face.boundingBox.center.dx, face.boundingBox.center.dy);

    final assessor = ref.read(qualityAssessorProvider);
    // Pass the active challenge so the assessor relaxes the right gates:
    // turnLeft/turnRight tolerate off-axis poses, blink tolerates a
    // missing eye-open probability on the closed frame, etc. Once
    // liveness has passed we fall back to the strictest "facing forward"
    // gates for the match-time embedding extraction.
    final quality = assessor.assess(face, frameSize,
        currentStep: state.livenessPassed ? null : state.challenge,
        brightness: brightness);
    // F-6: coalesce the faces+frameSize update with the quality update
    // into a single `copyWith` per happy-path frame. The previous
    // two-step (`faces+frameSize`, then later `quality`) allocated two
    // `VerificationState` instances per frame and produced two
    // rebuilds; merging halves that churn without changing observable
    // behaviour — neither `_motion.recordCentroid` nor
    // `assessor.assess` read any of the fields being deferred.
    state = state.copyWith(
      faces: faces,
      frameSize: frameSize,
      quality: quality,
    );
    if (!quality.isGood) return;

    if (!state.livenessPassed) {
      // O-5: while the user is still completing the liveness challenge,
      // speculatively prepare + extract a probe on this good frame so
      // the match step has it cached when the challenge passes.
      // Fire-and-forget — failures (busy isolate, bad frame, screen-refl,
      // blur) are silently dropped; the slow path in `_runMatch` will
      // recompute if no cached probe is fresh by then.
      unawaited(_maybeSpeculate(raw, face));
      _handleChallenge(face);
      return;
    }

    // Anti-spoof gate (§7.2): if the bbox centroid hasn't moved across
    // the rolling window, treat as a print/static-screen attack and short-
    // circuit before the embedding step.
    if (_motion.isStatic()) {
      _log.warning('Spoof: motion variance below floor — denying.');
      await _denyForSpoof();
      return;
    }

    // Anti-spoof gate (L3): device accelerometer also shows no motion.
    // Stacks with the face-bbox gate above: face-bbox stillness catches
    // printed-photo replays, device stillness catches phone-on-tripod
    // *video* replays where the face inside the video does move. The
    // fail-open behaviour (no IMU samples → buffer not full → returns
    // false) keeps us conservative on emulators / sensorless devices.
    if (_deviceMotion.isStatic()) {
      _log.warning('Spoof: device motion variance below floor — denying.');
      await _denyForSpoof();
      return;
    }

    await _runMatch(raw, face);
  }

  /// Dispatches per-attempt liveness detection to the handler matching
  /// the randomised challenge. Each handler updates `state.livenessPassed`
  /// when its motion has been observed. Returning without setting
  /// `livenessPassed=true` means "keep watching" — the next frame will
  /// re-enter through this same path.
  void _handleChallenge(FaceData face) {
    switch (state.challenge) {
      case LivenessStep.blink:
        _handleBlink(face);
      case LivenessStep.mouthOpen:
        _handleMouthOpen(face);
      case LivenessStep.turnLeft:
        _handleTurn(face, leftward: true);
      case LivenessStep.turnRight:
        _handleTurn(face, leftward: false);
      case LivenessStep.still:
        // `still` is intentionally excluded from verifyChallengeOptions
        // (a static photo trivially passes it). Defensive default: treat
        // a single good-quality frame as sufficient. Reached only if a
        // future code change adds `still` to the option set.
        state = state.copyWith(
          livenessPassed: true,
          status: 'Matching Identity...',
        );
    }
  }

  /// BLINK: open → closed → open. The leading "open" frame is required
  /// (matches the FSM contract) so a user arriving with closed eyes
  /// can't advance on the next open frame.
  void _handleBlink(FaceData face) {
    final lRaw = face.leftEyeOpen;
    final rRaw = face.rightEyeOpen;
    final l = lRaw ?? (state.eyeOpenSeen ? 0.0 : 1.0);
    final r = rRaw ?? (state.eyeOpenSeen ? 0.0 : 1.0);

    if (l > FaceThresholds.eyeOpen && r > FaceThresholds.eyeOpen) {
      state = state.copyWith(eyeOpenSeen: true);
      if (state.isBlinking) {
        state = state.copyWith(
          livenessPassed: true,
          isBlinking: false,
          eyeOpenSeen: false,
          status: 'Matching Identity...',
        );
        _log.fine('Liveness (blink) passed.');
      }
    } else if (state.eyeOpenSeen &&
        l < FaceThresholds.eyeClosed &&
        r < FaceThresholds.eyeClosed) {
      state = state.copyWith(
        isBlinking: true,
        status: 'Blink to verify...',
      );
    }
  }

  /// MOUTH_OPEN: open mouth (ratio > mouthOpenEnter) → close
  /// (ratio < mouthCloseExit). Mirrors the enrolment FSM's hysteresis
  /// thresholds so the verify side doesn't drift from the calibration
  /// the user already learned at enrol time. Returns silently when ML
  /// Kit can't compute the ratio (missing landmarks) — the next frame
  /// re-tries.
  void _handleMouthOpen(FaceData face) {
    final ratio = _mouthOpenRatio(face);
    if (ratio == null) return;

    if (!_mouthOpened) {
      if (ratio > FaceThresholds.mouthOpenEnter) {
        _mouthOpened = true;
        state = state.copyWith(status: 'Now close your mouth.');
      }
    } else if (ratio < FaceThresholds.mouthCloseExit) {
      state = state.copyWith(
        livenessPassed: true,
        status: 'Matching Identity...',
      );
      _log.fine('Liveness (mouth open → close) passed.');
    }
  }

  /// TURN_LEFT / TURN_RIGHT: yaw reaches the threshold in the prescribed
  /// direction, then returns near centre (|yaw| < stillAngle) so the
  /// match-phase embedding is extracted from a forward-facing frame.
  /// The "return to centre" step is what keeps probes comparable to the
  /// forward-facing enrolment templates.
  void _handleTurn(FaceData face, {required bool leftward}) {
    final yaw = face.headEulerY;
    final reached = leftward
        ? yaw > FaceThresholds.yawTurn
        : yaw < -FaceThresholds.yawTurn;

    if (!_turnReached) {
      if (reached) {
        _turnReached = true;
        state = state.copyWith(
            status: leftward
                ? 'Good — now look back at the camera.'
                : 'Good — now look back at the camera.');
      }
    } else if (yaw.abs() < FaceThresholds.stillAngle) {
      state = state.copyWith(
        livenessPassed: true,
        status: 'Matching Identity...',
      );
      _log.fine('Liveness (turn ${leftward ? "left" : "right"}) passed.');
    }
  }

  /// Nose-to-mouth distance / inter-eye distance. Mirrors the same
  /// ratio used by [LivenessStateMachine] so verify and enrol agree
  /// on what "open" / "closed" looks like.
  double? _mouthOpenRatio(FaceData face) {
    final leftEye = face.landmarks[FaceLandmarkType.leftEye];
    final rightEye = face.landmarks[FaceLandmarkType.rightEye];
    final nose = face.landmarks[FaceLandmarkType.noseBase];
    final mouth = face.landmarks[FaceLandmarkType.bottomMouth];
    if (leftEye == null || rightEye == null || nose == null || mouth == null) {
      return null;
    }
    final dx = (leftEye.x - rightEye.x).toDouble();
    final dy = (leftEye.y - rightEye.y).toDouble();
    final eyeDist = sqrt(dx * dx + dy * dy);
    if (eyeDist < 20) return null;
    final mdx = (nose.x - mouth.x).toDouble();
    final mdy = (nose.y - mouth.y).toDouble();
    final noseToMouth = sqrt(mdx * mdx + mdy * mdy);
    final ratio = noseToMouth / eyeDist;
    if (ratio < 0.3 || ratio > 1.5) return null;
    return ratio;
  }

  /// Defense-in-depth: zero the cached speculative probe's bytes and
  /// null the reference. Called from every attempt-boundary path
  /// (stale frame, dialog dismissal, controller dispose) so a probe
  /// never crosses an attempt that the user did not intend.
  void _clearSpeculativeProbe() {
    final c = _speculativeProbe;
    if (c == null) return;
    for (var i = 0; i < c.embedding.length; i++) {
      c.embedding[i] = 0;
    }
    _speculativeProbe = null;
  }

  /// O-5: best-effort speculative prepare + extract during the liveness
  /// phase. Runs the same gates as `_runMatch`'s slow path so a cached
  /// probe is always from a frame that *would have* passed match-time
  /// validation. Any failure silently abandons — there is always the
  /// slow path in `_runMatch` to fall back to.
  Future<void> _maybeSpeculate(CameraImage raw, FaceData face) async {
    if (_inSpeculation) return;
    // Don't trample a fresh cached probe — the embedding isolate is
    // single-flight and the match path may be racing us right now.
    final existing = _speculativeProbe;
    if (existing != null &&
        DateTime.now().difference(existing.at).inMilliseconds < 400) {
      return;
    }
    _inSpeculation = true;
    final completer = Completer<void>();
    _speculationCompleter = completer;
    try {
      final format = _rawFrameFormat(raw);
      if (format == null) return;
      final leftEye = face.landmarks[FaceLandmarkType.leftEye];
      final rightEye = face.landmarks[FaceLandmarkType.rightEye];
      final extractor = ref.read(embeddingExtractorProvider);

      Uint8List rgb112;
      try {
        rgb112 = await extractor.prepare(
          rawBytes: raw.planes.first.bytes,
          width: raw.width,
          height: raw.height,
          format: format,
          bbox: face.boundingBox,
          leftEyeX: leftEye?.x,
          leftEyeY: leftEye?.y,
          rightEyeX: rightEye?.x,
          rightEyeY: rightEye?.y,
        );
      } catch (_) {
        return; // includes EmbeddingBusyError — the match path won the race
      }
      if (_disposed) return;

      // Mirror _runMatch's host-side gates. We treat their failures as
      // "this frame isn't a good speculation candidate" — not as denies
      // or spoof flags. The slow path will re-evaluate on its own frame.
      if (_screenReflection.isLikelyScreen(rgb112)) return;
      final blur = BlurMetric.varianceOfLaplacian(
        rgb112,
        FaceThresholds.inputSize,
        FaceThresholds.inputSize,
      );
      if (blur < FaceThresholds.minBlurVariance) return;

      Float32List embedding;
      try {
        embedding = await extractor.extract(rgb112);
      } catch (_) {
        return;
      }
      if (_disposed) return;

      _speculativeProbe = (embedding: embedding, at: DateTime.now());
    } finally {
      _inSpeculation = false;
      _speculationCompleter = null;
      if (!completer.isCompleted) completer.complete();
    }
  }

  Future<void> _runMatch(CameraImage raw, FaceData face) async {
    // UTC matches the use case's default clock so the verify-log
    // timestamps remain timezone-consistent regardless of where the
    // attempt timestamp originates (this controller's spoof short-
    // circuit vs. VerifyUser's clock).
    final attemptStart = DateTime.now().toUtc();
    final attemptStopwatch = Stopwatch()..start();
    state = state.copyWith(isVerifying: true, status: 'Matching Identity...');
    try {
      // O-5 fast path: if speculation cached a probe during liveness on
      // a frame that already cleared screen-refl + blur, reuse it now —
      // saves the ~15 ms prepare + ~30 ms extract round-trip and skips
      // straight to rate-limit + match. The cache TTL (500 ms) is short
      // enough that the probe still reflects the user actively in front
      // of the camera, not a stale frame from earlier in the session.
      //
      // First: if a speculation is *still in flight* (it dispatched to
      // the isolate just before the user completed liveness), await it
      // briefly so the cache has a chance to land before we read it.
      // Without this wait, we'd race into the slow path's `prepare()`
      // while the isolate is single-flight-busy and hit
      // `EmbeddingBusyError`.
      final inFlight = _speculationCompleter;
      if (inFlight != null && !inFlight.isCompleted) {
        await inFlight.future.timeout(
          const Duration(milliseconds: 120),
          onTimeout: () {},
        );
        if (_disposed) return;
      }
      final cached = _speculativeProbe;
      final cacheAgeMs = cached == null
          ? -1
          : DateTime.now().difference(cached.at).inMilliseconds;
      final canUseCache = cached != null && cacheAgeMs < 500;

      Uint8List? rgb112;
      Float32List? speculativeEmbedding;

      if (canUseCache) {
        speculativeEmbedding = cached.embedding;
        _speculativeProbe = null;
        _log.fine('Using speculative probe (age=${cacheAgeMs}ms)');
      } else {
        final format = _rawFrameFormat(raw);
        if (format == null) {
          state = state.copyWith(
              isVerifying: false, status: 'Frame format unsupported');
          return;
        }
        // Phase D: decode + crop + eye-align + resize runs on the embedding
        // isolate so the UI thread stays free to repaint the preview
        // during a verify. The host-side gates below still run on the
        // prepared 112×112 buffer so their status copy and error paths
        // stay intact.
        final leftEye = face.landmarks[FaceLandmarkType.leftEye];
        final rightEye = face.landmarks[FaceLandmarkType.rightEye];
        final extractor = ref.read(embeddingExtractorProvider);
        try {
          rgb112 = await extractor.prepare(
            rawBytes: raw.planes.first.bytes,
            width: raw.width,
            height: raw.height,
            format: format,
            bbox: face.boundingBox,
            leftEyeX: leftEye?.x,
            leftEyeY: leftEye?.y,
            rightEyeX: rightEye?.x,
            rightEyeY: rightEye?.y,
          );
        } on EmbeddingBusyError {
          // The isolate is still serving an in-flight speculation we
          // raced past the await above (e.g. it landed within the 120 ms
          // window but the cache wasn't fresh enough). Step back to idle
          // — the next frame will either find a fresh cached probe
          // (fast path) or the isolate will be free for a clean
          // prepare. Don't surface "format unsupported": the frame is
          // fine, the resource was just briefly busy.
          state = state.copyWith(isVerifying: false);
          return;
        } catch (e, st) {
          _log.warning('Frame preparation failed', e, st);
          state = state.copyWith(
              isVerifying: false, status: 'Frame format unsupported');
          return;
        }
        if (_disposed) return;

        // Anti-spoof gate (§7.3): cheap saturation/luma check on the same
        // crop the embedding extractor would consume. Phone-on-phone
        // replay typically lights up here. (Speculation already passed
        // this gate at cache time, so the fast path can skip it.)
        if (_screenReflection.isLikelyScreen(rgb112)) {
          _log.warning('Spoof: screen reflection signal — denying.');
          await _denyForSpoof(
            start: attemptStart,
            latencyMs: attemptStopwatch.elapsedMilliseconds,
          );
          return;
        }

        // Sharpness gate (Phase B): reject motion-blurred frames before
        // the ~30 ms embedding-isolate dispatch. (Same speculation
        // reasoning as above.)
        final blur = BlurMetric.varianceOfLaplacian(
          rgb112,
          FaceThresholds.inputSize,
          FaceThresholds.inputSize,
        );
        if (blur < FaceThresholds.minBlurVariance) {
          _log.fine('Blur gate: variance=$blur below floor — holding.');
          state = state.copyWith(
              isVerifying: false, status: 'Hold steady — frame is blurry');
          return;
        }
      }

      // Pre-flight rate-limit check: cheap secure-storage read; only
      // happens once per attempt (after blink), not per frame.
      final rl = ref.read(rateLimiterProvider);
      final rlDecision = await rl.check();
      if (rlDecision is RateLimitCoolingDown) {
        final until = DateTime.now().add(rlDecision.retryAfter);
        state = state.copyWith(
          isVerifying: false,
          showResult: true,
          cooldownUntil: until,
          status: 'Too many attempts',
        );
        return;
      }

      final useCase = ref.read(verifyUserUseCaseProvider);
      final flat = state.flat ?? FlatTemplates.empty;
      final decision = await useCase.call(
        rgb112: rgb112,
        embedding: speculativeEmbedding,
        templates: flat,
      );

      if (_disposed) return;

      if (decision is VerifyGranted) {
        await rl.reset();
        state = state.copyWith(
          matchedUser: decision.user,
          showResult: true,
          isVerifying: false,
          bestSimilarity: decision.similarity,
          status: 'Verified!',
        );
        // Best-effort spoken announcement; never throws.
        unawaited(
          ref
              .read(ttsAnnouncerProvider)
              .speak('Identity confirmed, ${decision.user.name}'),
        );
      } else if (decision is VerifyDenied) {
        // Only count "real" denies (no-match / spoof) against the rate
        // limit. Infra errors don't burn the user's quota.
        if (decision.reason == VerificationFailure.noMatch ||
            decision.reason == VerificationFailure.spoof) {
          await rl.recordFailure();
          // Re-check to learn whether saturation just engaged.
          final post = await rl.check();
          DateTime? cooldownUntil;
          if (post is RateLimitCoolingDown) {
            cooldownUntil = DateTime.now().add(post.retryAfter);
          }
          state = state.copyWith(
            showResult: true,
            isVerifying: false,
            bestSimilarity: decision.bestSimilarity ?? 0,
            cooldownUntil: cooldownUntil,
            status: cooldownUntil != null
                ? 'Too many attempts'
                : 'Match Failed',
          );
        } else {
          state = state.copyWith(
            showResult: true,
            isVerifying: false,
            bestSimilarity: decision.bestSimilarity ?? 0,
            status: _statusForReason(decision.reason),
          );
        }
      }
    } catch (e, st) {
      _log.severe('Verification error', e, st);
      state = state.copyWith(
          isVerifying: false, status: 'Verification Error');
    }
  }

  void dismissResult() {
    // Anti-spoof: reset both motion buffers so a previous static-frame
    // verdict (face or device) doesn't leak into the next attempt's
    // first second. The accelerometer subscription stays alive — the
    // detector buffer fills again as new samples flow in.
    _motion.reset();
    _deviceMotion.reset();
    _resetChallengeProgress();
    _clearSpeculativeProbe();
    // Pick a fresh challenge so an attacker who saw the prior prompt
    // can't pre-record the next one. The pick is uniform with
    // replacement, so consecutive attempts can repeat — that's the
    // honest 1-in-N probability we want.
    state = state.copyWith(
      showResult: false,
      challenge: _pickChallenge(),
      livenessPassed: false,
      isBlinking: false,
      eyeOpenSeen: false,
      isVerifying: false,
      clearMatchedUser: true,
      status: 'Scanning face...',
    );
    // F-4: only re-warm when the bank has actually mutated since the
    // last warm. The verify result dialog is modal — the user cannot
    // enrol or delete from inside it — so the common path is
    // revision-unchanged and the AES-GCM decrypt is skipped entirely.
    // The revision counter still picks up legitimate mutations from a
    // sibling tab / future code path that bumps it during the dialog.
    final currentRevision = ref.read(userBankRevisionProvider);
    if (currentRevision != _lastWarmedRevision) {
      unawaited(_warmTemplates());
    }
  }

  /// Spoof short-circuit: writes a `verification_logs` row, records a
  /// rate-limit failure, and surfaces a denied result. Used by both anti-
  /// spoof gates (motion variance and screen reflection). Mirrors what the
  /// `VerifyDenied` branch in `_runMatch` does for `noMatch`/`spoof` from
  /// the use case, so the UX is identical regardless of where the spoof
  /// signal fires.
  Future<void> _denyForSpoof({
    DateTime? start,
    int latencyMs = 0,
  }) async {
    // UTC fallback so spoof denials match the timezone basis of grants
    // / regular denials. `start`, when provided, is already UTC because
    // it originates from `_runMatch.attemptStart`.
    final at = start ?? DateTime.now().toUtc();
    final logRepo = ref.read(verificationLogRepositoryProvider);
    final rl = ref.read(rateLimiterProvider);

    await logRepo.append(
      VerificationLog(
        userId: null,
        at: at,
        outcome: VerificationOutcome.spoof,
        failureReason: VerificationFailure.spoof.wireName,
        bestSimilarity: null,
        latencyMs: latencyMs,
      ),
    );
    await rl.recordFailure();
    final post = await rl.check();
    DateTime? cooldownUntil;
    if (post is RateLimitCoolingDown) {
      cooldownUntil = DateTime.now().add(post.retryAfter);
    }
    if (_disposed) return;
    state = state.copyWith(
      showResult: true,
      isVerifying: false,
      bestSimilarity: 0,
      cooldownUntil: cooldownUntil,
      status: cooldownUntil != null
          ? 'Too many attempts'
          : 'Spoof attempt detected',
    );
  }

  // -------------------------------------------------------------- utils --

  /// Maps the active `CameraImage` plane format to the wire-level
  /// [RawFrameFormat] understood by the embedding isolate's prepare
  /// codepath. Returns `null` when neither Android NV21 nor iOS BGRA8888
  /// is present — the caller surfaces that as "Frame format unsupported"
  /// the same way the old [_buildExtractorPayload] null-return did.
  static RawFrameFormat? _rawFrameFormat(CameraImage raw) {
    switch (raw.format.group) {
      case ImageFormatGroup.nv21:
        return RawFrameFormat.nv21;
      case ImageFormatGroup.bgra8888:
        return RawFrameFormat.bgra8888;
      default:
        return null;
    }
  }

  static String _statusForReason(VerificationFailure reason) {
    return switch (reason) {
      VerificationFailure.extractionFailed => 'Extraction failed. Try again.',
      VerificationFailure.error => 'Verification Error',
      VerificationFailure.noMatch => 'Match Failed',
      VerificationFailure.spoof => 'Spoof attempt detected',
      VerificationFailure.timeout => 'Verification timed out',
      VerificationFailure.rateLimited => 'Too many attempts',
      _ => 'Match Failed',
    };
  }

  static double _approximateBrightness(CameraImage raw) {
    if (raw.planes.isEmpty) return 128;
    final bytes = raw.planes.first.bytes;
    if (bytes.isEmpty) return 128;
    var sum = 0;
    final step = (bytes.length / 1024).ceil().clamp(1, 64);
    var count = 0;
    for (var i = 0; i < bytes.length; i += step) {
      sum += bytes[i];
      count++;
    }
    return count == 0 ? 128 : sum / count;
  }

}

final verificationControllerProvider =
    AutoDisposeNotifierProvider<VerificationController, VerificationState>(
        VerificationController.new);
