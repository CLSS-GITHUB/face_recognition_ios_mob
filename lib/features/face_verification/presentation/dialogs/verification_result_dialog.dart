import 'package:flutter/material.dart';

import '../../domain/entities/user.dart';

class VerificationResultDialog extends StatelessWidget {
  const VerificationResultDialog({
    super.key,
    required this.matched,
    required this.onDismiss,
  });

  final User? matched;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final granted = matched != null;
    return AlertDialog(
      icon: Icon(
        granted ? Icons.verified_user_rounded : Icons.error_rounded,
        size: 48,
        color: granted ? const Color(0xFF4CAF50) : scheme.error,
      ),
      title: Text(
        granted ? 'Access Granted' : 'Access Denied',
        textAlign: TextAlign.center,
      ),
      content: Text(
        granted
            ? 'Identity confirmed for ${matched!.name}.'
            : 'Face does not match any enrolled user.',
        textAlign: TextAlign.center,
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: onDismiss,
            child: const Text('OK'),
          ),
        ),
      ],
    );
  }
}
