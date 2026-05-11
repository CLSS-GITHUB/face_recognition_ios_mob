import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:image/image.dart' as img;

import '../../../../core/di/providers.dart';
import '../../../../core/utils/bitmap_utils.dart';
import '../../../../core/utils/camera_image_converter.dart';
import '../../domain/entities/face_data.dart';
import '../../domain/entities/liveness_step.dart';
import '../../domain/entities/quality_result.dart';
import '../widgets/camera_preview_widget.dart';
import '../widgets/circular_progress_segments.dart';
import '../widgets/face_overlay.dart';
import '../widgets/instruction_card.dart';

/// Debug-only screen wired into the router via /debug. Validates the Phase 2
/// pipeline end-to-end: live camera → ML Kit faces → quality → liveness step
/// state → on-demand embedding extraction.
class DebugCameraScreen extends ConsumerStatefulWidget {
  const DebugCameraScreen({super.key});

  @override
  ConsumerState<DebugCameraScreen> createState() => _DebugCameraScreenState();
}

class _DebugCameraScreenState extends ConsumerState<DebugCameraScreen> {
  List<FaceData> _faces = const [];
  Size _frameSize = Size.zero;
  QualityResult? _quality;
  LivenessStep? _step;
  int _completedSteps = 0;
  String _status = 'Position your face';

  bool _capturePending = false;
  String? _embeddingPreview;
  bool _extracting = false;

  @override
  void initState() {
    super.initState();
    final liveness = ref.read(livenessStateMachineProvider);
    liveness.onStepCompleted = (step) {
      if (!mounted) return;
      setState(() {
        _completedSteps =
            (_completedSteps + 1).clamp(0, liveness.totalSteps);
        _status = '${step.name} done';
      });
    };
    liveness.onAllStepsCompleted = () {
      if (!mounted) return;
      setState(() => _status = 'All liveness steps complete');
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recognizerAsync = ref.watch(faceRecognitionServiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Phase 2 Debug Harness')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 280,
                height: 280,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressSegments(
                      completedSteps: _completedSteps,
                      totalSteps: 5,
                    ),
                    SizedBox(
                      width: 230,
                      height: 230,
                      child: ClipOval(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreviewWidget(onFrame: _handleFrame),
                            FaceOverlay(faces: _faces, frameSize: _frameSize),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              InstructionCard(
                step: _step,
                status: _status,
                quality: _quality,
              ),
              const SizedBox(height: 12),
              recognizerAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Loading TFLite model…'),
                ),
                error: (e, _) => Text(
                  'TFLite load failed: $e',
                  style: TextStyle(color: scheme.error),
                ),
                data: (_) => FilledButton.icon(
                  onPressed: _extracting
                      ? null
                      : () => setState(() => _capturePending = true),
                  icon: _extracting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt_rounded),
                  label: const Text('Capture & Extract Embedding'),
                ),
              ),
              if (_embeddingPreview != null) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _embeddingPreview!,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleFrame(CameraImage raw, InputImage forMlKit) async {
    final detector = ref.read(faceDetectionServiceProvider);
    final assessor = ref.read(qualityAssessorProvider);
    final liveness = ref.read(livenessStateMachineProvider);

    final faces = await detector.detect(forMlKit);
    if (!mounted) return;
    final frameSize = forMlKit.metadata?.size ?? Size.zero;

    QualityResult? quality;
    if (faces.length > 1) {
      quality = const QualityResult.failed(['Multiple faces detected.']);
    } else if (faces.isEmpty) {
      quality = const QualityResult.failed(['No face detected']);
    } else {
      final brightness = _approximateBrightness(raw);
      quality = assessor.assess(
        faces.first,
        frameSize,
        currentStep: liveness.currentStep,
        brightness: brightness,
      );
      if (quality.isGood) {
        liveness.process(faces.first);
      }
    }

    if (mounted) {
      setState(() {
        _faces = faces;
        _frameSize = frameSize;
        _quality = quality;
        _step = liveness.currentStep;
      });
    }

    if (_capturePending && faces.length == 1) {
      _capturePending = false;
      await _extractEmbeddingFromFrame(raw, faces.first);
    }
  }

  Future<void> _extractEmbeddingFromFrame(CameraImage raw, FaceData face) async {
    setState(() => _extracting = true);
    try {
      final image = _cameraImageToRgbImage(raw);
      if (image == null) {
        setState(() => _embeddingPreview = 'Frame format not supported on this platform');
        return;
      }
      final crop = BitmapUtils.cropFace(image, face.boundingBox);
      final recognizer =
          ref.read(faceRecognitionServiceProvider).requireValue;
      final embedding = await recognizer.extractEmbedding(crop, face);
      final preview = embedding
          .take(8)
          .map((v) => v.toStringAsFixed(4))
          .join(', ');
      setState(() {
        _embeddingPreview =
            '${embedding.length}-D L2-normalized embedding\nfirst 8: [$preview]';
      });
    } catch (e) {
      setState(() => _embeddingPreview = 'Extraction failed: $e');
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  /// Best-effort brightness estimate from the Y plane (NV21) or BGRA luminance.
  double _approximateBrightness(CameraImage raw) {
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

  /// Decode the raw frame to an RGB `image.Image`. Returns null when the
  /// platform delivered a format we don't decode here. Currently supports
  /// NV21 (Android) and BGRA8888 (iOS).
  img.Image? _cameraImageToRgbImage(CameraImage raw) {
    if (Platform.isAndroid) {
      if (raw.format.group != ImageFormatGroup.nv21) return null;
      final bytes = raw.planes.first.bytes;
      final rgb = Nv21Decoder.nv21ToRgb(bytes, raw.width, raw.height);
      return BitmapUtils.rgbBytesToImage(rgb, raw.width, raw.height);
    }
    if (Platform.isIOS) {
      if (raw.format.group != ImageFormatGroup.bgra8888) return null;
      return _bgraToImage(raw.planes.first.bytes, raw.width, raw.height);
    }
    return null;
  }

  img.Image _bgraToImage(Uint8List bgra, int width, int height) {
    final rgb = Uint8List(width * height * 3);
    var di = 0;
    for (var i = 0; i < bgra.length; i += 4) {
      rgb[di++] = bgra[i + 2];
      rgb[di++] = bgra[i + 1];
      rgb[di++] = bgra[i];
    }
    return BitmapUtils.rgbBytesToImage(rgb, width, height);
  }
}

