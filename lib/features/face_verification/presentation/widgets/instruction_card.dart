import 'package:flutter/material.dart';

import '../../../../app/theme/colors.dart';
import '../../domain/entities/liveness_step.dart';
import '../../domain/entities/quality_result.dart';

/// Mirrors EnrollmentScreen.kt's InstructionCard composable: shows the active
/// step instruction, current status line, and any quality issues. Optional
/// retry button when the controller signals a failure.
class InstructionCard extends StatelessWidget {
  const InstructionCard({
    super.key,
    required this.step,
    required this.status,
    this.quality,
    this.onRetry,
  });

  final LivenessStep? step;
  final String status;
  final QualityResult? quality;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isError =
        quality?.isGood == false || status.contains('failed') || status.contains('blurry');
    final headline = step?.instruction ?? _statusHeadline(status);

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              headline,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isError ? Icons.warning_rounded : Icons.check_circle_rounded,
                  size: 20,
                  color: isError ? scheme.error : AppColors.success,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    status,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isError ? scheme.error : scheme.onSurface,
                        ),
                  ),
                ),
              ],
            ),
            if (status.contains('failed') && onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Try Again'),
              ),
            ],
            if (quality?.isGood == false) ...[
              const SizedBox(height: 12),
              ...quality!.issues.map(
                (issue) => Text(
                  '• $issue',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusHeadline(String status) {
    if (status.contains('Frame') || status.contains('Capturing')) {
      return 'Capturing Biometrics';
    }
    return 'Position your face';
  }
}
