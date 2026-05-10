import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';

import '../../../../core/constants/thresholds.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/platform/rate_limiter.dart';
import '../../../../core/utils/bitmap_utils.dart';
import '../../../../core/utils/camera_image_converter.dart';
import '../../../../core/utils/image_processing.dart';
import '../../domain/entities/face_data.dart';
import '../../domain/entities/liveness_step.dart';
import '../../domain/entities/quality_result.dart';
import '../../domain/entities/user.dart';
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
    required this.blinkDetected,
    required this.isBlinking,
    required this.eyeOpenSeen,
    required this.flat,
    required this.isReady,
    required this.bestSimilarity,
    required this.cooldownUntil,
  });

  const VerificationState.initial()
      : status = 'Scanning face...',
        quality = null,
        faces = const [],
        frameSize = Size.zero,
        isVerifying = false,
        matchedUser = null,
        showResult = false,
        blinkDetected = false,
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
  final bool blinkDetected;
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
    bool? blinkDetected,
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
      blinkDetected: blinkDetected ?? this.blinkDetected,
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

  /// Anti-spoof: cheap saturation+luma heuristic on the 112×112 RGB crop
  /// — phone-on-phone replay produces unnaturally vivid + bright pixels.
  /// Stateless; see §7.3.
  static const _screenReflection = ScreenReflectionDetector();

  /// Restarted on every frame; if it fires, the camera stream stalled
  /// (architecture §3.2 step 2 / §3.4 frameStaleMs).
  Timer? _staleFrameWatchdog;

  @override
  VerificationState build() {
    ref.onDispose(() {
      _disposed = true;
      _staleFrameWatchdog?.cancel();
      _staleFrameWatchdog = null;
    });
    Future.microtask(_warmTemplates);
    return const VerificationState.initial();
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
    state = state.copyWith(
      blinkDetected: false,
      isBlinking: false,
      eyeOpenSeen: false,
      faces: const [],
      clearQuality: true,
      status: 'Camera stalled — moving back to scan.',
    );
  }

  Future<void> _warmTemplates() async {
    try {
      final flat =
          await ref.read(userRepositoryProvider).activeFlatTemplates();
      if (_disposed) return;
      state = state.copyWith(flat: flat, isReady: true);
      _log.fine('Pre-warmed ${flat.count} templates from '
          '${flat.map.toSet().length} users');
    } catch (e, st) {
      _log.severe('Failed to pre-warm templates', e, st);
      state = state.copyWith(
          isReady: true,
          status: 'Database unavailable',
          flat: FlatTemplates(flat: _empty, map: const []));
    }
  }

  static final Float32List _empty = Float32List(0);

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
    final faces = await detector.detect(forMlKit);
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
    final brightness = _approximateBrightness(raw);

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
    state = state.copyWith(faces: faces, frameSize: frameSize);

    // Anti-spoof bookkeeping: feed every well-detected single face's bbox
    // centroid into the motion-variance ring buffer so we can decide
    // whether the frame is "alive" before we burn the embedding budget
    // (architecture §7.2). The detector is cheap and stateful — even
    // pre-blink frames count toward the rolling window so by the time
    // we reach the match path we already have a verdict.
    _motion.recordCentroid(face.boundingBox.center.dx, face.boundingBox.center.dy);

    final assessor = ref.read(qualityAssessorProvider);
    final quality = assessor.assess(face, frameSize,
        currentStep: state.blinkDetected ? null : LivenessStep.blink,
        brightness: brightness);
    state = state.copyWith(quality: quality);
    if (!quality.isGood) return;

    if (!state.blinkDetected) {
      final lRaw = face.leftEyeOpen;
      final rRaw = face.rightEyeOpen;

      final l = lRaw ?? (state.eyeOpenSeen ? 0.0 : 1.0);
      final r = rRaw ?? (state.eyeOpenSeen ? 0.0 : 1.0);

      if (l > FaceThresholds.eyeOpen && r > FaceThresholds.eyeOpen) {
        state = state.copyWith(eyeOpenSeen: true);
        if (state.isBlinking) {
          state = state.copyWith(
              blinkDetected: true,
              isBlinking: false,
              eyeOpenSeen: false,
              status: 'Matching Identity...');
          _log.fine('Liveness (blink) passed.');
        }
      } else if (state.eyeOpenSeen &&
          l < FaceThresholds.eyeClosed &&
          r < FaceThresholds.eyeClosed) {
        state = state.copyWith(
            isBlinking: true, status: 'Blink to verify...');
      }
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

    await _runMatch(raw, face);
  }

  Future<void> _runMatch(CameraImage raw, FaceData face) async {
    final attemptStart = DateTime.now();
    final attemptStopwatch = Stopwatch()..start();
    state = state.copyWith(isVerifying: true, status: 'Matching Identity...');
    try {
      final rgb112 = _buildExtractorPayload(raw, face);
      if (rgb112 == null) {
        state = state.copyWith(
            isVerifying: false, status: 'Frame format unsupported');
        return;
      }

      // Anti-spoof gate (§7.3): cheap saturation/luma check on the same
      // crop the embedding extractor would consume. Phone-on-phone replay
      // typically lights up here.
      if (_screenReflection.isLikelyScreen(rgb112)) {
        _log.warning('Spoof: screen reflection signal — denying.');
        await _denyForSpoof(
          start: attemptStart,
          latencyMs: attemptStopwatch.elapsedMilliseconds,
        );
        return;
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
      final flat = state.flat ?? FlatTemplates(flat: _empty, map: const []);
      final decision = await useCase.call(rgb112: rgb112, templates: flat);

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
    // Anti-spoof: reset the motion buffer so a previous static-frame
    // verdict doesn't leak into the next attempt's first second.
    _motion.reset();
    state = state.copyWith(
      showResult: false,
      blinkDetected: false,
      isBlinking: false,
      eyeOpenSeen: false,
      isVerifying: false,
      clearMatchedUser: true,
      status: 'Scanning face...',
    );
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
    final at = start ?? DateTime.now();
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

  /// Decode → crop → align/enhance → resize 112×112 → flatten to RGB bytes.
  /// Returns the 37,632-byte payload [EmbeddingExtractor] expects, or null
  /// if the camera frame format is unsupported.
  static Uint8List? _buildExtractorPayload(CameraImage raw, FaceData face) {
    final image = _decodeFrame(raw);
    if (image == null) return null;
    final crop = BitmapUtils.cropFace(image, face.boundingBox);
    final aligned = ImageProcessing.alignAndMaybeEnhance(crop, face);
    final resized = img.copyResize(
      aligned,
      width: FaceThresholds.inputSize,
      height: FaceThresholds.inputSize,
      interpolation: img.Interpolation.linear,
    );
    return Uint8List.fromList(
      resized.getBytes(order: img.ChannelOrder.rgb),
    );
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

  static img.Image? _decodeFrame(CameraImage raw) {
    if (Platform.isAndroid) {
      if (raw.format.group != ImageFormatGroup.nv21) return null;
      final rgb =
          Nv21Decoder.nv21ToRgb(raw.planes.first.bytes, raw.width, raw.height);
      return BitmapUtils.rgbBytesToImage(rgb, raw.width, raw.height);
    }
    if (Platform.isIOS) {
      if (raw.format.group != ImageFormatGroup.bgra8888) return null;
      final bgra = raw.planes.first.bytes;
      final rgb = Uint8List(raw.width * raw.height * 3);
      var di = 0;
      for (var i = 0; i < bgra.length; i += 4) {
        rgb[di++] = bgra[i + 2];
        rgb[di++] = bgra[i + 1];
        rgb[di++] = bgra[i];
      }
      return BitmapUtils.rgbBytesToImage(rgb, raw.width, raw.height);
    }
    return null;
  }
}

final verificationControllerProvider =
    AutoDisposeNotifierProvider<VerificationController, VerificationState>(
        VerificationController.new);
