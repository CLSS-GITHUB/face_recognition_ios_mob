import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:logging/logging.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/utils/camera_image_converter.dart';

/// F-2: gate per-frame `print` calls behind a build-time flag. Flutter's
/// `print` lands in logcat under the `flutter` tag which is throttled to
/// 12 KB/s; at 30 fps a small log on every frame would saturate that
/// budget and stall a frame. The const value lets the compiler elide the
/// log calls entirely when the flag is unset (the default in normal
/// builds). Re-enable with `--dart-define=PER_FRAME_LOG=true` when
/// debugging the camera pipeline.
const bool _kPerFrameLog = bool.fromEnvironment(
  'PER_FRAME_LOG',
  defaultValue: false,
);

typedef OnFrame = Future<void> Function(
  CameraImage raw,
  InputImage forMlKit,
);

/// Front-camera live preview with frame streaming and back-pressure.
///
/// Reproduces CameraX's STRATEGY_KEEP_ONLY_LATEST: while [onFrame] is busy,
/// new frames are dropped — never queued.
///
/// F-1: the underlying `CameraController` is owned by
/// `cameraControllerProvider` (a `keepAlive` Riverpod provider) so the
/// ~250-500 ms initialise cost is paid once during verify-prewarm rather
/// than on every screen mount. This widget only manages the image-stream
/// subscription against that shared controller — it does NOT dispose the
/// controller on widget teardown.
class CameraPreviewWidget extends ConsumerStatefulWidget {
  const CameraPreviewWidget({
    super.key,
    required this.onFrame,
  });

  final OnFrame onFrame;

  @override
  ConsumerState<CameraPreviewWidget> createState() =>
      _CameraPreviewWidgetState();
}

class _CameraPreviewWidgetState extends ConsumerState<CameraPreviewWidget> {
  static final Logger _log = Logger('CameraPreviewWidget');

  CameraController? _controller;
  bool _busy = false;
  String? _error;
  int _diagFrames = 0;

  /// Tracks whether THIS widget instance has started a stream on the
  /// shared controller. Two safety properties depend on this:
  /// 1. `dispose` only calls `stopImageStream` if WE started it (a
  ///    previous widget instance might own the stream; we should not
  ///    yank it).
  /// 2. `_bootstrap` re-entry (e.g. hot reload) is idempotent.
  bool _streamStarted = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final controller = await ref.read(cameraControllerProvider.future);
      if (!mounted) return;
      // Defensive: if a previous widget left the stream running and
      // didn't get a chance to stop it (hot restart, exception path),
      // tear it down so our `startImageStream` doesn't double-fire.
      if (controller.value.isStreamingImages) {
        try {
          await controller.stopImageStream();
        } catch (e, st) {
          _log.warning('Defensive stopImageStream failed', e, st);
        }
      }
      await controller.startImageStream(_onCameraImage);
      _streamStarted = true;
      if (!mounted) {
        // The widget was disposed while we awaited startImageStream.
        // Tear down what we just started — the provider keeps the
        // controller alive for the next widget instance.
        try {
          await controller.stopImageStream();
        } catch (_) {}
        return;
      }
      setState(() => _controller = controller);
    } catch (e, st) {
      _log.severe('Camera bootstrap failed', e, st);
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onCameraImage(CameraImage image) {
    _diagFrames++;
    if (_kPerFrameLog && (_diagFrames <= 10 || _diagFrames % 30 == 0)) {
      // ignore: avoid_print
      print('[FRAME $_diagFrames] busy=$_busy '
          'formatRaw=${image.format.raw} group=${image.format.group}');
    }
    final controller = _controller;
    if (controller == null || _busy) return;
    final input = CameraImageConverter.toInputImage(
      image,
      controller.description,
      controller.value.deviceOrientation,
    );
    if (_kPerFrameLog && _diagFrames <= 10) {
      // ignore: avoid_print
      print('[FRAME $_diagFrames] devOrient=${controller.value.deviceOrientation} '
          'sensor=${controller.description.sensorOrientation} '
          'inputImage=${input == null ? "NULL" : "OK"}');
    }
    if (input == null) return;
    _busy = true;
    Future.microtask(() async {
      try {
        await widget.onFrame(image, input);
      } finally {
        _busy = false;
      }
    });
  }

  @override
  void dispose() {
    // F-1: we own only the image-stream subscription, not the controller
    // itself. Stop the stream so the next widget instance (verify ↔
    // enroll navigation) can start a fresh one bound to its own
    // callbacks. The controller stays initialised in the provider.
    final c = _controller;
    if (c != null && _streamStarted) {
      c.stopImageStream().catchError((e, st) {
        _log.warning('stopImageStream on widget dispose failed', e, st);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
        ),
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return CameraPreview(c);
  }
}
