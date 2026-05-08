import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/constants/thresholds.dart';
import '../../../../core/di/providers.dart';
import '../../../../core/utils/bitmap_utils.dart';
import '../../../../core/utils/camera_image_converter.dart';
import '../../domain/entities/enrollment_result.dart';
import '../../domain/entities/enrollment_stage.dart';
import '../../domain/entities/face_data.dart';
import '../../domain/entities/liveness_step.dart';
import '../../domain/entities/quality_result.dart';

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
  Future<void> processFrame(CameraImage raw, InputImage forMlKit) async {
    if (state.isProcessingFrame || state.stage == EnrollmentStage.registration) {
      return;
    }
    final detector = ref.read(faceDetectionServiceProvider);
    final faces = await detector.detect(forMlKit);
    if (_disposed) return;
    final frameSize = forMlKit.metadata?.size ?? Size.zero;
    final brightness = _approximateBrightness(raw);

    if (faces.length > 1) {
      state = state.copyWith(
        faces: faces,
        frameSize: frameSize,
        quality: const QualityResult.failed(
            ['Multiple faces detected. Only one person allowed.']),
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

    switch (state.stage) {
      case EnrollmentStage.liveness:
        await _handleLivenessStage(raw, face, frameSize, brightness);
      case EnrollmentStage.verify:
        await _handleVerifyStage(raw, face, frameSize, brightness);
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
      final crop = BitmapUtils.cropFace(image, face.boundingBox);
      final recognizer =
          await ref.read(faceRecognitionServiceProvider.future);
      final embedding = await recognizer.extractEmbedding(crop, face);
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
    final quality =
        assessor.assess(face, frameSize, brightness: brightness);
    state = state.copyWith(quality: quality);
    if (!quality.isGood) return;

    if (!state.verificationBlinkDetected) {
      final l = face.leftEyeOpen ?? 1.0;
      final r = face.rightEyeOpen ?? 1.0;
      if (l < FaceThresholds.eyeClosed && r < FaceThresholds.eyeClosed) {
        state = state.copyWith(
            isVerificationBlinking: true,
            verificationStatus: 'Blink to verify...');
      } else if (state.isVerificationBlinking &&
          l > FaceThresholds.eyeOpen &&
          r > FaceThresholds.eyeOpen) {
        state = state.copyWith(
          verificationBlinkDetected: true,
          isVerificationBlinking: false,
          verificationStatus: 'Verifying...',
        );
      }
      return;
    }

    state = state.copyWith(
        isProcessingFrame: true, verificationStatus: 'Verifying...');
    try {
      final image = _decodeFrame(raw);
      if (image == null) {
        state = state.copyWith(
            isProcessingFrame: false,
            verificationStatus: 'Frame format unsupported');
        return;
      }
      final crop = BitmapUtils.cropFace(image, face.boundingBox);
      final recognizer =
          await ref.read(faceRecognitionServiceProvider.future);
      final verifyEmbedding = await recognizer.extractEmbedding(crop, face);
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
  }) async {
    final embedding = state.capturedEmbedding;
    if (embedding == null) {
      throw StateError('register() called before embedding captured');
    }
    final useCase = ref.read(enrollUserUseCaseProvider);
    return useCase.call(
      userCode: userCode,
      userName: userName,
      embedding: embedding,
      imagePath: state.capturedImagePath,
    );
  }

  void retryAll() {
    ref.read(livenessStateMachineProvider).reset();
    state = const EnrollmentState.initial();
  }

  void retryVerification() {
    state = state.copyWith(
      verificationBlinkDetected: false,
      isVerificationBlinking: false,
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
