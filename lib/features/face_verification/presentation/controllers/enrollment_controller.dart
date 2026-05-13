import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'
    show FaceLandmarkType;
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/constants/thresholds.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/utils/bitmap_utils.dart';
import '../../../../core/utils/blur_metric.dart';
import '../../../../core/utils/camera_image_converter.dart';
import '../../../../core/utils/frame_preparation.dart';
import '../../domain/entities/enrollment_result.dart';
import '../../domain/entities/enrollment_stage.dart';
import '../../domain/entities/face_data.dart';
import '../../domain/entities/liveness_step.dart';
import '../../domain/entities/quality_result.dart';

/// F-2: gate per-frame `print` calls behind a build-time flag. Same
/// reasoning as the verify-side widget — flutter-tag logcat is
/// throttled and a verbose per-frame trace silently drops other useful
/// log lines. Re-enable with `--dart-define=PER_FRAME_LOG=true`.
const bool _kPerFrameLog = bool.fromEnvironment(
  'PER_FRAME_LOG',
  defaultValue: false,
);

class EnrollmentState {
  const EnrollmentState({
    required this.stage,
    required this.currentStep,
    required this.completedSteps,
    required this.status,
    required this.faces,
    required this.frameSize,
    required this.quality,
    required this.isProcessingFrame,
    required this.extractionRetryCount,
    required this.capturedEmbedding,
    required this.capturedImagePath,
    required this.verificationBlinkDetected,
    required this.isVerificationBlinking,
    required this.verificationEyeOpenSeen,
    required this.verificationStatus,
    required this.showVerificationFailed,
  });

  const EnrollmentState.initial()
      : stage = EnrollmentStage.liveness,
        currentStep = LivenessStep.blink,
        completedSteps = 0,
        status = 'Position your face',
        faces = const [],
        frameSize = Size.zero,
        quality = null,
        isProcessingFrame = false,
        extractionRetryCount = 0,
        capturedEmbedding = null,
        capturedImagePath = null,
        verificationBlinkDetected = false,
        isVerificationBlinking = false,
        verificationEyeOpenSeen = false,
        verificationStatus = 'Blink to confirm enrollment',
        showVerificationFailed = false;

  final EnrollmentStage stage;
  final LivenessStep? currentStep;
  final int completedSteps;
  final String status;
  final List<FaceData> faces;
  final Size frameSize;
  final QualityResult? quality;
  final bool isProcessingFrame;
  final int extractionRetryCount;
  final Float32List? capturedEmbedding;
  final String? capturedImagePath;
  final bool verificationBlinkDetected;
  final bool isVerificationBlinking;
  final bool verificationEyeOpenSeen;
  final String verificationStatus;
  final bool showVerificationFailed;

  EnrollmentState copyWith({
    EnrollmentStage? stage,
    LivenessStep? currentStep,
    bool clearStep = false,
    int? completedSteps,
    String? status,
    List<FaceData>? faces,
    Size? frameSize,
    QualityResult? quality,
    bool clearQuality = false,
    bool? isProcessingFrame,
    int? extractionRetryCount,
    Float32List? capturedEmbedding,
    bool clearEmbedding = false,
    String? capturedImagePath,
    bool? verificationBlinkDetected,
    bool? isVerificationBlinking,
    bool? verificationEyeOpenSeen,
    String? verificationStatus,
    bool? showVerificationFailed,
  }) {
    return EnrollmentState(
      stage: stage ?? this.stage,
      currentStep: clearStep ? null : (currentStep ?? this.currentStep),
      completedSteps: completedSteps ?? this.completedSteps,
      status: status ?? this.status,
      faces: faces ?? this.faces,
      frameSize: frameSize ?? this.frameSize,
      quality: clearQuality ? null : (quality ?? this.quality),
      isProcessingFrame: isProcessingFrame ?? this.isProcessingFrame,
      extractionRetryCount: extractionRetryCount ?? this.extractionRetryCount,
      capturedEmbedding:
          clearEmbedding ? null : (capturedEmbedding ?? this.capturedEmbedding),
      capturedImagePath: capturedImagePath ?? this.capturedImagePath,
      verificationBlinkDetected:
          verificationBlinkDetected ?? this.verificationBlinkDetected,
      isVerificationBlinking:
          isVerificationBlinking ?? this.isVerificationBlinking,
      verificationEyeOpenSeen:
          verificationEyeOpenSeen ?? this.verificationEyeOpenSeen,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      showVerificationFailed:
          showVerificationFailed ?? this.showVerificationFailed,
    );
  }
}

class EnrollmentController extends AutoDisposeNotifier<EnrollmentState> {
  static final Logger _log = Logger('EnrollmentController');
  static const _uuid = Uuid();

  bool _disposed = false;

  @override
  EnrollmentState build() {
    ref.onDispose(() => _disposed = true);
    final liveness = ref.read(livenessStateMachineProvider);
    liveness.reset();
    liveness.onStepCompleted = (step) {
      if (_disposed) return;
      state = state.copyWith(
        completedSteps:
            (state.completedSteps + 1).clamp(0, liveness.totalSteps),
        status: '${_humanize(step)} done',
      );
    };
    liveness.onAllStepsCompleted = () {
      if (_disposed) return;
      state = state.copyWith(status: 'Liveness Passed! Capturing...');
    };
    return const EnrollmentState.initial();
  }

  // -------------------------------------------------------------- frame --
  static int _processFrameCalls = 0;
  Future<void> processFrame(CameraImage raw, InputImage forMlKit) async {
    final n = ++_processFrameCalls;
    final rotation = forMlKit.metadata?.rotation;
    final frameSize = forMlKit.metadata?.size ?? Size.zero;

    if (_kPerFrameLog && (n <= 5 || n % 30 == 0)) {
      // ignore: avoid_print
      print('[PROC $n] enter stage=${state.stage} '
          'size=${frameSize.width.toInt()}x${frameSize.height.toInt()} '
          'rot=${rotation?.rawValue}');
    }

    if (state.isProcessingFrame ||
        state.stage == EnrollmentStage.registration) {
      return;
    }
    final detector = ref.read(enrollmentFaceDetectionServiceProvider);
    List<FaceData> faces;
    try {
      faces = await detector.detect(forMlKit).timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          // Timeout is a real warning even in non-verbose mode — leave
          // this through the proper logger so it always lands.
          _log.warning('[PROC $n] DETECT TIMEOUT');
          return const <FaceData>[];
        },
      );
    } catch (e, st) {
      _log.warning('[PROC $n] DETECT THREW', e, st);
      return;
    }

    if (_kPerFrameLog &&
        (n <= 5 || (faces.isEmpty && n % 30 == 0) || (faces.isNotEmpty && n % 10 == 0))) {
      // ignore: avoid_print
      print('[PROC $n] after detect faces=${faces.length}');
    }

    if (_disposed) return;
    final brightness = _approximateBrightness(raw);

    // ML Kit returns face bounding boxes in the ROTATED image's coordinate
    // space (per the rotation hint we pass in InputImageMetadata). Our raw
    // frame is 720x480 (landscape) but with rotation270deg ML Kit's bbox is
    // in 480x720 portrait coords. The quality assessor compares bbox center
    // against frame dimensions, so it needs the rotated dimensions too —
    // otherwise centering checks always fail.
    final isQuarterRotated = rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final adjustedFrameSize = isQuarterRotated
        ? Size(frameSize.height, frameSize.width)
        : frameSize;

    if (_kPerFrameLog && faces.isNotEmpty) {
      final face = faces.first;
      if (n % 10 == 0) {
        // ignore: avoid_print
        print('[PROC $n] face: box=${face.boundingBox} '
            'lEye=${face.leftEyeOpen?.toStringAsFixed(2)} '
            'rEye=${face.rightEyeOpen?.toStringAsFixed(2)}');
      }
    }

    if (faces.length > 1) {
      state = state.copyWith(
        faces: faces,
        frameSize: adjustedFrameSize,
        quality: const QualityResult.failed(
            ['Multiple faces detected. Only one person allowed.']),
      );
      return;
    }
    if (faces.isEmpty) {
      state = state.copyWith(
        faces: faces,
        frameSize: adjustedFrameSize,
        quality: const QualityResult.failed(['No face detected']),
      );
      return;
    }

    final face = faces.first;
    state = state.copyWith(faces: faces, frameSize: adjustedFrameSize);

    switch (state.stage) {
      case EnrollmentStage.liveness:
        await _handleLivenessStage(raw, face, adjustedFrameSize, brightness);
      case EnrollmentStage.verify:
        await _handleVerifyStage(raw, face, adjustedFrameSize, brightness);
      case EnrollmentStage.registration:
        break;
    }
  }

  Future<void> _handleLivenessStage(
    CameraImage raw,
    FaceData face,
    Size frameSize,
    double brightness,
  ) async {
    if (state.capturedEmbedding != null) return;
    final assessor = ref.read(qualityAssessorProvider);
    final liveness = ref.read(livenessStateMachineProvider);

    final quality = assessor.assess(face, frameSize,
        currentStep: liveness.currentStep, brightness: brightness);
    if (_kPerFrameLog) {
      // ignore: avoid_print
      print('[STAGE] step=${liveness.currentStep} qualityOk=${quality.isGood} '
          'issues=${quality.issues} brightness=${brightness.toStringAsFixed(0)} '
          'yaw=${face.headEulerY.toStringAsFixed(1)} '
          'pitch=${face.headEulerX.toStringAsFixed(1)}');
    }
    state = state.copyWith(quality: quality, currentStep: liveness.currentStep);
    if (!quality.isGood) return;

    liveness.process(face);
    state = state.copyWith(
      currentStep: liveness.currentStep,
      clearStep: liveness.currentStep == null,
    );

    if (liveness.currentStep != null) return;

    final isNeutral =
        face.headEulerY.abs() < 5 && face.headEulerX.abs() < 10;
    if (!isNeutral) {
      state = state.copyWith(status: 'Hold Still & Look Straight');
      return;
    }

    state = state.copyWith(
        isProcessingFrame: true, status: 'Capturing Biometrics...');
    try {
      final image = _decodeFrame(raw);
      if (image == null) {
        state = state.copyWith(
            isProcessingFrame: false, status: 'Frame format unsupported');
        return;
      }
      // Crop kept for the JPEG side-effect (saved alongside the user
      // row). The embedding pipeline runs against an independent
      // crop+align+resize via [BitmapUtils.buildExtractorPayload] so it
      // stays byte-identical with the verify probe.
      final crop = BitmapUtils.cropFace(image, face.boundingBox);
      final payload = BitmapUtils.buildExtractorPayload(image, face);
      // Sharpness gate (Phase B): keep the retry FSM spinning until the
      // capture frame is sharp enough that the embedding won't drift in
      // the noisy band — far better than baking a blurry template into
      // the user row, which would then poison every subsequent verify.
      final blur = BlurMetric.varianceOfLaplacian(
        payload,
        FaceThresholds.inputSize,
        FaceThresholds.inputSize,
      );
      if (blur < FaceThresholds.minBlurVariance) {
        _log.fine('Enrol blur gate: variance=$blur below floor — holding.');
        state = state.copyWith(
            isProcessingFrame: false,
            status: 'Hold steady — frame is blurry');
        return;
      }
      // Off-UI TFLite via the long-lived embedding isolate — same path
      // the verify flow uses. Pays the spawn cost once (provider is
      // keepAlive) and removes the ~50 ms UI hitch the previous host-
      // isolate FaceRecognitionService call caused at enrolment time.
      final extractor = ref.read(embeddingExtractorProvider);
      final embedding = await extractor.extract(payload);
      final isValid = embedding.isNotEmpty && embedding.any((v) => v != 0);
      if (isValid) {
        final imagePath = await BitmapUtils.saveJpeg(
            crop, 'user_${_uuid.v4()}');
        state = state.copyWith(
          stage: EnrollmentStage.verify,
          capturedEmbedding: embedding,
          capturedImagePath: imagePath,
          isProcessingFrame: false,
          status: 'Verify yourself with a blink',
        );
        _log.info('Initial capture successful — moving to verify stage.');
      } else {
        final next = state.extractionRetryCount + 1;
        if (next > FaceThresholds.extractionRetryLimit) {
          liveness.reset();
          state = state.copyWith(
            extractionRetryCount: 0,
            completedSteps: 0,
            status: 'Extraction failed. Restarting.',
            isProcessingFrame: false,
            currentStep: LivenessStep.blink,
          );
        } else {
          state = state.copyWith(
            extractionRetryCount: next,
            status:
                'Hold still... Frame $next/${FaceThresholds.extractionRetryLimit}',
            isProcessingFrame: false,
          );
        }
      }
    } catch (e, st) {
      _log.severe('Capture system error', e, st);
      state = state.copyWith(
          isProcessingFrame: false, status: 'Capture system error');
    }
  }

  Future<void> _handleVerifyStage(
    CameraImage raw,
    FaceData face,
    Size frameSize,
    double brightness,
  ) async {
    if (state.isProcessingFrame) return;
    final assessor = ref.read(qualityAssessorProvider);
    final quality = assessor.assess(face, frameSize,
        currentStep: LivenessStep.blink, brightness: brightness);
    state = state.copyWith(quality: quality);
    if (!quality.isGood) return;

    if (!state.verificationBlinkDetected) {
      final lRaw = face.leftEyeOpen;
      final rRaw = face.rightEyeOpen;

      final l = lRaw ?? (state.verificationEyeOpenSeen ? 0.0 : 1.0);
      final r = rRaw ?? (state.verificationEyeOpenSeen ? 0.0 : 1.0);

      if (l > FaceThresholds.eyeOpen && r > FaceThresholds.eyeOpen) {
        state = state.copyWith(verificationEyeOpenSeen: true);
        if (state.isVerificationBlinking) {
          state = state.copyWith(
            verificationBlinkDetected: true,
            isVerificationBlinking: false,
            verificationStatus: 'Verifying...',
          );
        }
      } else if (state.verificationEyeOpenSeen &&
          l < FaceThresholds.eyeClosed &&
          r < FaceThresholds.eyeClosed) {
        state = state.copyWith(
            isVerificationBlinking: true,
            verificationStatus: 'Blink to verify...');
      }
      return;
    }

    state = state.copyWith(
        isProcessingFrame: true, verificationStatus: 'Verifying...');
    try {
      final format = _rawFrameFormat(raw);
      if (format == null) {
        state = state.copyWith(
            isProcessingFrame: false,
            verificationStatus: 'Frame format unsupported');
        return;
      }
      // Phase D: hand decode+crop+align+resize off to the embedding
      // isolate so the camera preview stays smooth during the post-enrol
      // verify blink. Identical preprocessing to the verify controller —
      // both call the same FramePreparation inside the isolate.
      final leftEye = face.landmarks[FaceLandmarkType.leftEye];
      final rightEye = face.landmarks[FaceLandmarkType.rightEye];
      final extractor = ref.read(embeddingExtractorProvider);
      final Uint8List payload;
      try {
        payload = await extractor.prepare(
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
      } catch (e, st) {
        _log.warning('Verify-stage prepare failed', e, st);
        state = state.copyWith(
            isProcessingFrame: false,
            verificationStatus: 'Frame format unsupported');
        return;
      }
      // Same sharpness floor as the verify controller — a blurry verify
      // probe against a sharp enrolled template is the exact case the
      // gate was designed for.
      final blur = BlurMetric.varianceOfLaplacian(
        payload,
        FaceThresholds.inputSize,
        FaceThresholds.inputSize,
      );
      if (blur < FaceThresholds.minBlurVariance) {
        _log.fine('Verify-stage blur gate: variance=$blur — holding.');
        state = state.copyWith(
            isProcessingFrame: false,
            verificationStatus: 'Hold steady — frame is blurry');
        return;
      }
      final verifyEmbedding = await extractor.extract(payload);
      if (verifyEmbedding.isEmpty) {
        state = state.copyWith(
            isProcessingFrame: false,
            verificationStatus: 'Verification failed to extract.');
        return;
      }
      final matcher = ref.read(faceMatchingServiceProvider);
      final similarity =
          matcher.cosine(state.capturedEmbedding!, verifyEmbedding);
      _log.fine('Verification similarity: $similarity');
      if (similarity >= FaceThresholds.reEnrollVerifyThreshold) {
        state = state.copyWith(
          stage: EnrollmentStage.registration,
          verificationStatus: 'Verified!',
          isProcessingFrame: false,
        );
      } else {
        state = state.copyWith(
          showVerificationFailed: true,
          isProcessingFrame: false,
        );
      }
    } catch (e, st) {
      _log.severe('Verification error', e, st);
      state = state.copyWith(
          isProcessingFrame: false, verificationStatus: 'Verification Error');
    }
  }

  // ------------------------------------------------------ user actions --

  Future<EnrollmentResult> register({
    required String userCode,
    required String userName,
    bool wearsGlasses = false,
  }) async {
    final embedding = state.capturedEmbedding;
    if (embedding == null) {
      throw StateError('register() called before embedding captured');
    }
    final useCase = ref.read(enrollUserUseCaseProvider);
    final result = await useCase.call(
      userCode: userCode,
      userName: userName,
      embedding: embedding,
      imagePath: state.capturedImagePath,
      // Threaded from the enrol form's "Currently wearing glasses?"
      // switch via PendingEnrollment.wearsGlasses. Stamped into
      // FaceTemplateMeta so a later glasses-toggle re-enrol picks up
      // an opposite-state template alongside the original.
      wearsGlasses: wearsGlasses,
    );
    // F-4: enrol mutated the active bank. Bump the revision so the
    // verify screen re-decrypts on its next entry instead of running
    // against a stale flat-templates view.
    ref.read(userBankRevisionProvider.notifier).update((v) => v + 1);
    return result;
  }

  void retryAll() {
    ref.read(livenessStateMachineProvider).reset();
    state = const EnrollmentState.initial();
  }

  void retryVerification() {
    state = state.copyWith(
      verificationBlinkDetected: false,
      isVerificationBlinking: false,
      verificationEyeOpenSeen: false,
      showVerificationFailed: false,
      verificationStatus: 'Blink to confirm enrollment',
    );
  }

  void restartFromVerification() {
    ref.read(livenessStateMachineProvider).reset();
    state = const EnrollmentState.initial();
  }

  // -------------------------------------------------------------- utils --

  static String _humanize(LivenessStep step) =>
      step.name.replaceAll('_', ' ').toUpperCase();

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

  /// Maps the active `CameraImage` plane format to the wire-level
  /// [RawFrameFormat] understood by the embedding isolate's prepare
  /// codepath. Returns `null` when neither Android NV21 nor iOS BGRA8888
  /// is present.
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

final enrollmentControllerProvider =
    AutoDisposeNotifierProvider<EnrollmentController, EnrollmentState>(
        EnrollmentController.new);
