import 'package:flutter/material.dart';

class DeleteUserDialog extends StatelessWidget {
  const DeleteUserDialog({
    super.key,
    required this.userName,
    required this.onConfirm,
  });

  final String userName;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete User'),
      content: Text(
        'Are you sure you want to permanently delete $userName? '
        'This action cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: onConfirm,
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
