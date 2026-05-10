import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/enrollment_result.dart';
import '../../domain/entities/enrollment_stage.dart';
import '../controllers/enrollment_controller.dart';
import '../dialogs/registration_dialog.dart';
import '../dialogs/verification_failed_dialog.dart';
import '../widgets/camera_preview_widget.dart';
import '../widgets/circular_progress_segments.dart';
import '../widgets/face_overlay.dart';
import '../widgets/instruction_card.dart';
import 'pending_enrollment.dart';

class LiveEnrollmentScreen extends ConsumerStatefulWidget {
  const LiveEnrollmentScreen({super.key, this.pending});

  final PendingEnrollment? pending;

  @override
  ConsumerState<LiveEnrollmentScreen> createState() =>
      _LiveEnrollmentScreenState();
}

class _LiveEnrollmentScreenState extends ConsumerState<LiveEnrollmentScreen> {
  bool _registrationDialogOpen = false;
  bool _verificationFailedDialogOpen = false;

  @override
  Widget build(BuildContext context) {
    ref.listen(enrollmentControllerProvider, _reactToState);

    final state = ref.watch(enrollmentControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      // Wrap the body in LayoutBuilder + SingleChildScrollView + IntrinsicHeight
      // so the column fills the viewport when there's room (Spacer keeps the
      // Cancel button pinned to the bottom) AND scrolls cleanly on small or
      // landscape screens. Without this, the camera oval (300×300) plus the
      // surrounding chrome overflow on heights ≲ 640 px — see the
      // RenderFlex-overflowed-by-238px exception in the run log.
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
                        'Face Enrollment',
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
                            CircularProgressSegments(
                              completedSteps: state.completedSteps,
                              totalSteps: 5,
                            ),
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
                                            enrollmentControllerProvider
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
                        _bodyHint(state.stage),
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      InstructionCard(
                        step: state.stage == EnrollmentStage.verify
                            ? null
                            : state.currentStep,
                        status: state.stage == EnrollmentStage.verify
                            ? state.verificationStatus
                            : state.status,
                        quality: state.quality,
                        onRetry: () => ref
                            .read(enrollmentControllerProvider.notifier)
                            .retryAll(),
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

  String _bodyHint(EnrollmentStage stage) {
    return switch (stage) {
      EnrollmentStage.liveness =>
        'Move your head slowly to complete the circle.',
      EnrollmentStage.verify => 'One more blink to confirm enrollment.',
      EnrollmentStage.registration => 'Enter the user details to finish.',
    };
  }

  void _reactToState(EnrollmentState? prev, EnrollmentState next) {
    final justEnteredRegistration =
        prev?.stage != EnrollmentStage.registration &&
        next.stage == EnrollmentStage.registration;
    final justFailedVerification =
        (prev?.showVerificationFailed ?? false) == false &&
        next.showVerificationFailed;

    if (justEnteredRegistration && !_registrationDialogOpen) {
      _registrationDialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => RegistrationDialog(
            initialUserCode: widget.pending?.userCode ?? '',
            initialUserName: widget.pending?.userName ?? '',
            onConfirm: (code, name) async {
              final controller = ref.read(
                enrollmentControllerProvider.notifier,
              );
              final result = await controller.register(
                userCode: code,
                userName: name,
              );
              if (!mounted) return;
              Navigator.of(context).pop();
              _registrationDialogOpen = false;
              _showResultSnackBar(result);
              context.go('/home');
            },
            onRetryAll: () {
              Navigator.of(context).pop();
              _registrationDialogOpen = false;
              ref.read(enrollmentControllerProvider.notifier).retryAll();
            },
          ),
        );
      });
    }

    if (justFailedVerification && !_verificationFailedDialogOpen) {
      _verificationFailedDialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => VerificationFailedDialog(
            onRetryVerification: () {
              Navigator.of(context).pop();
              _verificationFailedDialogOpen = false;
              ref
                  .read(enrollmentControllerProvider.notifier)
                  .retryVerification();
            },
            onRestartEnrollment: () {
              Navigator.of(context).pop();
              _verificationFailedDialogOpen = false;
              ref
                  .read(enrollmentControllerProvider.notifier)
                  .restartFromVerification();
            },
          ),
        );
      });
    }
  }

  void _showResultSnackBar(EnrollmentResult result) {
    final messenger = ScaffoldMessenger.of(context);
    final text = switch (result) {
      NewUserEnrolled(:final user) => 'Enrolled ${user.name}.',
      TemplateAddedToExisting(:final user) => 'Added template to ${user.name}.',
      DuplicateTemplateSkipped(:final user) =>
        'Template already exists for ${user.name}.',
    };
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }
}
