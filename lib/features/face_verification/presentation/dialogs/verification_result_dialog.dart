import 'package:flutter/material.dart';

import '../../domain/entities/user.dart';

/// F-3: inline result panel. Replaces the old `showDialog`-driven
/// `VerificationResultDialog` so the verdict surfaces without paying
/// the ~150-250 ms Material modal-route transition. Rendered as part
/// of the verify screen's tree (stacked over the camera preview) and
/// faded in over a short window — instant feel without being jarring.
///
/// File kept at the `dialogs/` path despite no longer being a Material
/// dialog so existing imports / tests don't churn; the class name
/// reflects what it is now.
class VerificationResultPanel extends StatelessWidget {
  const VerificationResultPanel({
    super.key,
    required this.matched,
    required this.onDismiss,
  });

  /// The verified user, or `null` for a denied / no-match outcome. The
  /// panel keys its title + copy + icon off this field.
  final User? matched;

  /// Fired when the user taps the dismiss CTA. The verify controller's
  /// `dismissResult` is responsible for re-arming the FSM.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final granted = matched != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Scrim — captures taps outside the card so the camera preview
        // below doesn't keep feeding frames through the touch layer.
        // Visually a translucent black, matching the old dialog barrier.
        const ColoredBox(color: Color(0xCC000000)),
        SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Material(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(28),
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        granted
                            ? Icons.verified_user_rounded
                            : Icons.error_rounded,
                        size: 48,
                        color: granted
                            ? const Color(0xFF4CAF50)
                            : scheme.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        granted ? 'Access Granted' : 'Access Denied',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        granted
                            ? 'Identity confirmed for ${matched!.name}.'
                            : 'Face does not match any enrolled user.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: onDismiss,
                          child: const Text('OK'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
