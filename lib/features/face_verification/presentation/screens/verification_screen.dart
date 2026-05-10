import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/theme/colors.dart';
import '../../domain/entities/liveness_step.dart';
import '../controllers/verification_controller.dart';
import '../dialogs/verification_result_dialog.dart';
import '../widgets/camera_preview_widget.dart';
import '../widgets/face_overlay.dart';
import '../widgets/instruction_card.dart';

/// Verify Identity screen. Mirrors `LiveEnrollmentScreen` chrome (title,
/// circular camera oval, instruction card, cancel CTA) but drives the
/// verification controller's FSM instead of the enrolment one.
///
/// See `docs/verification/architecture_recommendations.md` §6.
class VerificationScreen extends ConsumerStatefulWidget {
  const VerificationScreen({super.key});

  @override
  ConsumerState<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends ConsumerState<VerificationScreen> {
  bool _resultDialogOpen = false;

  @override
  Widget build(BuildContext context) {
    ref.listen(verificationControllerProvider, _reactToState);

    final state = ref.watch(verificationControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      // LayoutBuilder + SingleChildScrollView + IntrinsicHeight: column fills
      // the viewport when there's room (Spacer keeps Cancel pinned to bottom),
      // and scrolls cleanly on small or landscape screens. Mirrors the same
      // fix on live_enrollment_screen.dart — both screens share the
      // 300×300 camera oval that overflows on heights ≲ 640 px.
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        'Verify Identity',
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: 300,
                        height: 300,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            _AlignmentRing(color: _ringColor(state)),
                            SizedBox(
                              width: 240,
                              height: 240,
                              child: ClipOval(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    CameraPreviewWidget(
                                      onFrame: (raw, input) => ref
                                          .read(
                                            verificationControllerProvider
                                                .notifier,
                                          )
                                          .processFrame(raw, input),
                                    ),
                                    FaceOverlay(
                                      faces: state.faces,
                                      frameSize: state.frameSize,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _bodyHint(state),
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      InstructionCard(
                        step: state.blinkDetected ? null : LivenessStep.blink,
                        status: state.status,
                        quality: state.quality,
                      ),
                      const Spacer(),
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: FilledButton.tonal(
                          onPressed: () => context.pop(),
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Ring colour mirrors architecture_recommendations.md §6.2:
  /// red = no face / poor quality, amber = quality ok / awaiting blink,
  /// green = matching / matched.
  Color _ringColor(VerificationState state) {
    if (!state.isReady) return AppColors.progressInactive;
    if (state.faces.length != 1) return Colors.red;
    final qualityOk = state.quality?.isGood ?? false;
    if (!qualityOk) return Colors.red;
    if (!state.blinkDetected) return Colors.amber;
    return AppColors.success;
  }

  String _bodyHint(VerificationState state) {
    if (!state.isReady) return 'Loading enrolled users…';
    if (state.matchedUser != null) return 'Identity confirmed.';
    if (state.isVerifying) return 'Matching against enrolled users…';
    if (state.blinkDetected) return 'Hold still while we verify.';
    return 'Look at the camera, then blink to verify.';
  }

  void _reactToState(VerificationState? prev, VerificationState next) {
    final justShownResult =
        (prev?.showResult ?? false) == false && next.showResult;
    if (!justShownResult || _resultDialogOpen) return;

    _resultDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => VerificationResultDialog(
          matched: next.matchedUser,
          onDismiss: () {
            Navigator.of(context).pop();
            _resultDialogOpen = false;
            ref.read(verificationControllerProvider.notifier).dismissResult();
          },
        ),
      );
    });
  }
}

/// Plain coloured oval ring drawn behind the camera preview. Replaces the
/// progress-segments ring used in enrolment — verification has no per-step
/// progress, just a single quality indicator.
class _AlignmentRing extends StatelessWidget {
  const _AlignmentRing({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 6),
      ),
    );
  }
}
