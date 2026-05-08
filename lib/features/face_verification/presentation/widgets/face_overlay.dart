import 'package:flutter/material.dart';

import '../../domain/entities/face_data.dart';

/// Draws bounding boxes and key landmark dots over the live camera preview.
/// Mirrors FaceOverlay.kt: cyan stroke for the box, red 6-px dots for
/// landmarks, with horizontal mirroring for the front camera (the preview
/// already shows the mirrored image, so the box has to follow).
class FaceOverlay extends StatelessWidget {
  const FaceOverlay({
    super.key,
    required this.faces,
    required this.frameSize,
    this.mirror = true,
  });

  final List<FaceData> faces;
  final Size frameSize;
  final bool mirror;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _FacePainter(faces: faces, frameSize: frameSize, mirror: mirror),
      size: Size.infinite,
    );
  }
}

class _FacePainter extends CustomPainter {
  _FacePainter({
    required this.faces,
    required this.frameSize,
    required this.mirror,
  });

  final List<FaceData> faces;
  final Size frameSize;
  final bool mirror;

  @override
  void paint(Canvas canvas, Size size) {
    if (frameSize.isEmpty) return;
    final scaleX = size.width / frameSize.width;
    final scaleY = size.height / frameSize.height;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    final dx = (size.width - frameSize.width * scale) / 2;
    final dy = (size.height - frameSize.height * scale) / 2;

    final boxPaint = Paint()
      ..color = const Color(0xFF00BCD4) // cyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    final dotPaint = Paint()
      ..color = const Color(0xFFE53935) // red
      ..style = PaintingStyle.fill;

    for (final face in faces) {
      final bbox = face.boundingBox;
      double left = bbox.left * scale + dx;
      double right = bbox.right * scale + dx;
      if (mirror) {
        final flippedLeft = size.width - right;
        final flippedRight = size.width - left;
        left = flippedLeft;
        right = flippedRight;
      }
      final rect = Rect.fromLTRB(
        left,
        bbox.top * scale + dy,
        right,
        bbox.bottom * scale + dy,
      );
      canvas.drawRect(rect, boxPaint);
      for (final p in face.landmarks.values) {
        var x = p.x * scale + dx;
        if (mirror) x = size.width - x;
        final y = p.y * scale + dy;
        canvas.drawCircle(Offset(x, y), 6, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_FacePainter old) =>
      old.faces != faces || old.frameSize != frameSize || old.mirror != mirror;
}
