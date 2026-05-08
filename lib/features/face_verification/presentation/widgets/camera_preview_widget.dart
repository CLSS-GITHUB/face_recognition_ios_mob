import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:logging/logging.dart';

import '../../../../core/utils/camera_image_converter.dart';

typedef OnFrame = Future<void> Function(
  CameraImage raw,
  InputImage forMlKit,
);

/// Front-camera live preview with frame streaming and back-pressure.
///
/// Reproduces CameraX's STRATEGY_KEEP_ONLY_LATEST: while [onFrame] is busy,
/// new frames are dropped — never queued.
class CameraPreviewWidget extends StatefulWidget {
  const CameraPreviewWidget({
    super.key,
    required this.onFrame,
    this.lensDirection = CameraLensDirection.front,
    this.resolution = ResolutionPreset.medium,
  });

  final OnFrame onFrame;
  final CameraLensDirection lensDirection;
  final ResolutionPreset resolution;

  @override
  State<CameraPreviewWidget> createState() => _CameraPreviewWidgetState();
}

class _CameraPreviewWidgetState extends State<CameraPreviewWidget> {
  static final Logger _log = Logger('CameraPreviewWidget');

  CameraController? _controller;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == widget.lensDirection,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        camera,
        widget.resolution,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      await controller.startImageStream(_onCameraImage);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e, st) {
      _log.severe('Camera bootstrap failed', e, st);
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onCameraImage(CameraImage image) {
    final controller = _controller;
    if (controller == null || _busy) return;
    final input = CameraImageConverter.toInputImage(
      image,
      controller.description,
      controller.description.sensorOrientation,
    );
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
    final c = _controller;
    if (c != null) {
      c.stopImageStream().catchError((_) {});
      c.dispose();
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
