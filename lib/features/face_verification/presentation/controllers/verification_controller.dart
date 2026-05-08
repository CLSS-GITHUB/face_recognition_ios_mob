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
import '../../../../core/utils/bitmap_utils.dart';
import '../../../../core/utils/camera_image_converter.dart';
import '../../domain/entities/face_data.dart';
import '../../domain/entities/quality_result.dart';
import '../../domain/entities/user.dart';
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
    required this.flat,
    required this.isReady,
    required this.bestSimilarity,
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
        flat = null,
        isReady = false,
        bestSimilarity = 0;

  final String status;
  final QualityResult? quality;
  final List<FaceData> faces;
  final Size frameSize;
  final bool isVerifying;
  final User? matchedUser;
  final bool showResult;
  final bool blinkDetected;
  final bool isBlinking;
  final FlatTemplates? flat;
  final bool isReady;
  final double bestSimilarity;

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
    FlatTemplates? flat,
    bool? isReady,
    double? bestSimilarity,
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
      flat: flat ?? this.flat,
      isReady: isReady ?? this.isReady,
      bestSimilarity: bestSimilarity ?? this.bestSimilarity,
    );
  }
}

class VerificationController extends AutoDisposeNotifier<VerificationState> {
  static final Logger _log = Logger('VerificationController');

  bool _disposed = false;

  @override
  VerificationState build() {
    ref.onDispose(() => _disposed = true);
    Future.microtask(_warmTemplates);
    return const VerificationState.initial();
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
    if (state.isVerifying || !state.isReady) return;

    final detector = ref.read(faceDetectionServiceProvider);
    final faces = await detector.detect(forMlKit);
    if (_disposed) return;
    final frameSize = forMlKit.metadata?.size ?? Size.zero;
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

    final assessor = ref.read(qualityAssessorProvider);
    final quality =
        assessor.assess(face, frameSize, brightness: brightness);
    state = state.copyWith(quality: quality);
    if (!quality.isGood) return;

    if (!state.blinkDetected) {
      final l = face.leftEyeOpen ?? 1.0;
      final r = face.rightEyeOpen ?? 1.0;
      if (l < FaceThresholds.eyeClosed && r < FaceThresholds.eyeClosed) {
        state = state.copyWith(
            isBlinking: true, status: 'Blink to verify...');
      } else if (state.isBlinking &&
          l > FaceThresholds.eyeOpen &&
          r > FaceThresholds.eyeOpen) {
        state = state.copyWith(
            blinkDetected: true,
            isBlinking: false,
            status: 'Matching Identity...');
        _log.fine('Liveness (blink) passed.');
      }
      return;
    }

    await _runMatch(raw, face);
  }

  Future<void> _runMatch(CameraImage raw, FaceData face) async {
    state = state.copyWith(isVerifying: true, status: 'Matching Identity...');
    try {
      final image = _decodeFrame(raw);
      if (image == null) {
        state = state.copyWith(
            isVerifying: false, status: 'Frame format unsupported');
        return;
      }
      final crop = BitmapUtils.cropFace(image, face.boundingBox);
      final recognizer =
          await ref.read(faceRecognitionServiceProvider.future);
      final probe = await recognizer.extractEmbedding(crop, face);
      if (probe.isEmpty) {
        state = state.copyWith(
            isVerifying: false, status: 'Extraction failed. Try again.');
        return;
      }

      final flat = state.flat;
      if (flat == null || flat.isEmpty) {
        _log.info('No active templates — denying.');
        state = state.copyWith(
          showResult: true,
          isVerifying: false,
          bestSimilarity: 0,
          status: 'Match Failed',
        );
        return;
      }

      final matcher = ref.read(faceMatchingServiceProvider);
      final result = matcher.findBestMatch(probe, flat.flat, flat.count);
      if (result.isMatch) {
        final user = flat.map[result.index];
        _log.info('MATCH FOUND (similarity: ${result.similarity})');
        state = state.copyWith(
          matchedUser: user,
          showResult: true,
          isVerifying: false,
          bestSimilarity: result.similarity,
          status: 'Verified!',
        );
      } else {
        _log.warning('NO MATCH (best: ${result.similarity})');
        state = state.copyWith(
          showResult: true,
          isVerifying: false,
          bestSimilarity: result.similarity < -1 ? 0 : result.similarity,
          status: 'Match Failed',
        );
      }
    } catch (e, st) {
      _log.severe('Verification error', e, st);
      state = state.copyWith(
          isVerifying: false, status: 'Verification Error');
    }
  }

  void dismissResult() {
    state = state.copyWith(
      showResult: false,
      blinkDetected: false,
      isBlinking: false,
      isVerifying: false,
      clearMatchedUser: true,
      status: 'Scanning face...',
    );
  }

  // -------------------------------------------------------------- utils --

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
