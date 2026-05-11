import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/theme/colors.dart';
import '../../../../core/di/providers.dart';
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
/// UI states the user sees, in order:
///   1. `!isReady`       → spinner + "Loading enrolled users…".
///   2. No face / poor   → red alignment ring + quality hint.
///   3. Quality ok       → amber ring + "Blink to verify".
///   4. Blink detected   → green ring + spinner overlay + "Matching…".
///   5. Result           → modal dialog, ring frozen until dismissed.
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
  void initState() {
    super.initState();
    // O-6: wake the TTS engine while the user is still doing the
    // liveness challenge. The first speak() on Android pays a one-shot
    // ~50 ms engine init; doing it now keeps the granted-result
    // announcement instant. Best-effort — failure here changes nothing.
    unawaited(ref.read(ttsAnnouncerProvider).prewarm());
  }

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
                                    // Matching-in-progress overlay. Dimmed
                                    // backdrop + spinner appears the moment
                                    // the controller flips `isVerifying`
                                    // (after blink). Animated so it fades
                                    // in/out without flicker between
                                    // back-to-back frames.
                                    AnimatedOpacity(
                                      duration:
                                          const Duration(milliseconds: 150),
                                      opacity: state.isVerifying ? 1.0 : 0.0,
                                      child: IgnorePointer(
                                        ignoring: !state.isVerifying,
                                        child: const ColoredBox(
                                          color: Color(0x66000000),
                                          child: Center(
                                            child: SizedBox(
                                              width: 56,
                                              height: 56,
                                              child:
                                                  CircularProgressIndicator(
                                                strokeWidth: 4,
                                                valueColor:
                                                    AlwaysStoppedAnimation(
                                                        Colors.white),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    // Pre-warm overlay. Shown until the
                                    // template bank is loaded and decrypted.
                                    // Without this, the user sees a green
                                    // camera oval but no feedback that the
                                    // app is still bootstrapping.
                                    if (!state.isReady)
                                      const ColoredBox(
                                        color: Color(0xAA000000),
                                        child: Center(
                                          child: SizedBox(
                                            width: 40,
                                            height: 40,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 3,
                                              valueColor:
                                                  AlwaysStoppedAnimation(
                                                      Colors.white),
                                            ),
                                          ),
                                        ),
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
                        // Show the active challenge until it's been
                        // performed, then drop the headline so the
                        // status line ("Matching Identity…") takes
                        // over. Same pattern as the previous
                        // blink-only flow.
                        step: state.livenessPassed
                            ? null
                            : state.challenge,
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
  /// red = no face / poor quality, amber = quality ok / awaiting the
  /// challenge motion, green = matching / matched.
  Color _ringColor(VerificationState state) {
    // While the bank is still being decrypted, render the ring inactive
    // (neutral grey) — green or amber here would suggest the pipeline is
    // ready when it actually isn't, leading users to act too early.
    if (!state.isReady) return AppColors.progressInactive;
    if (state.faces.length != 1) return Colors.red;
    final qualityOk = state.quality?.isGood ?? false;
    if (!qualityOk) return Colors.red;
    if (!state.livenessPassed) return Colors.amber;
    return AppColors.success;
  }

  /// Short, user-facing description of the current step. Kept terse —
  /// the InstructionCard below this row carries the detailed message.
  /// The body hint changes per random challenge so the user always
  /// reads the right prompt for *this* attempt's required motion.
  String _bodyHint(VerificationState state) {
    if (!state.isReady) return 'Loading enrolled users…';
    if (state.matchedUser != null) return 'Identity confirmed.';
    if (state.isVerifying) return 'Matching against enrolled users…';
    if (state.livenessPassed) return 'Hold still while we verify.';
    if (state.faces.isEmpty) return 'Position your face inside the oval.';
    if (state.faces.length > 1) {
      return 'Only one face at a time, please.';
    }
    return switch (state.challenge) {
      LivenessStep.blink => 'Look at the camera, then blink to verify.',
      LivenessStep.mouthOpen =>
          'Look at the camera, then open and close your mouth.',
      LivenessStep.turnLeft =>
          'Turn your head to the left, then face the camera again.',
      LivenessStep.turnRight =>
          'Turn your head to the right, then face the camera again.',
      LivenessStep.still => 'Hold still and face the camera.',
    };
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
