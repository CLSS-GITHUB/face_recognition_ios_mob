import 'package:flutter/material.dart';

class VerificationFailedDialog extends StatelessWidget {
  const VerificationFailedDialog({
    super.key,
    required this.onRetryVerification,
    required this.onRestartEnrollment,
  });

  final VoidCallback onRetryVerification;
  final VoidCallback onRestartEnrollment;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Verification Failed'),
      content: const Text(
        'The secondary verification did not match the initial capture. '
        'Please ensure you are looking straight at the camera.',
      ),
      actions: [
        TextButton(
          onPressed: onRestartEnrollment,
          child: const Text('Restart Enrollment'),
        ),
        FilledButton(
          onPressed: onRetryVerification,
          child: const Text('Retry Verification'),
        ),
      ],
    );
  }
}
