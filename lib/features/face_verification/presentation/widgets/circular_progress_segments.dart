import 'package:flutter/material.dart';

import '../../../../app/theme/colors.dart';

/// Mirrors EnrollmentScreen.kt's CircularProgressSegments composable —
/// 5 segments with 4° gaps, active segments in primary, inactive in light.
class CircularProgressSegments extends StatelessWidget {
  const CircularProgressSegments({
    super.key,
    required this.completedSteps,
    required this.totalSteps,
    this.strokeWidth = 8,
    this.gapDegrees = 4,
  });

  final int completedSteps;
  final int totalSteps;
  final double strokeWidth;
  final double gapDegrees;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SegmentsPainter(
        completed: completedSteps,
        total: totalSteps,
        strokeWidth: strokeWidth,
        gapDegrees: gapDegrees,
      ),
      size: Size.infinite,
    );
  }
}

class _SegmentsPainter extends CustomPainter {
  _SegmentsPainter({
    required this.completed,
    required this.total,
    required this.strokeWidth,
    required this.gapDegrees,
  });

  final int completed;
  final int total;
  final double strokeWidth;
  final double gapDegrees;

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final rect = Offset.zero & size;
    final segmentDeg = (360 / total) - gapDegrees;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth;
    for (var i = 0; i < total; i++) {
      final startDeg = -90 + i * (segmentDeg + gapDegrees) + gapDegrees / 2;
      paint.color =
          i < completed ? AppColors.progressActive : AppColors.progressInactive;
      canvas.drawArc(
        rect.deflate(strokeWidth / 2),
        startDeg * 3.1415926535 / 180,
        segmentDeg * 3.1415926535 / 180,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SegmentsPainter old) =>
      old.completed != completed ||
      old.total != total ||
      old.strokeWidth != strokeWidth ||
      old.gapDegrees != gapDegrees;
}
