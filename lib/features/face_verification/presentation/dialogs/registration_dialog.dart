import 'package:flutter/material.dart';

/// Final-stage dialog from EnrollmentScreen.kt: collects userCode + userName
/// and triggers the duplicate / dedup logic via [onConfirm]. Dismissible only
/// via the "Retry All" button.
class RegistrationDialog extends StatefulWidget {
  const RegistrationDialog({
    super.key,
    required this.initialUserCode,
    required this.initialUserName,
    required this.onConfirm,
    required this.onRetryAll,
  });

  final String initialUserCode;
  final String initialUserName;
  final Future<void> Function(String userCode, String userName) onConfirm;
  final VoidCallback onRetryAll;

  @override
  State<RegistrationDialog> createState() => _RegistrationDialogState();
}

class _RegistrationDialogState extends State<RegistrationDialog> {
  late final TextEditingController _userCode =
      TextEditingController(text: widget.initialUserCode);
  late final TextEditingController _userName =
      TextEditingController(text: widget.initialUserName);
  bool _busy = false;

  @override
  void dispose() {
    _userCode.dispose();
    _userName.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_busy &&
      _userCode.text.trim().isNotEmpty &&
      _userName.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Enroll Face'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Enter your details to save the biometric template.'),
          const SizedBox(height: 16),
          TextField(
            controller: _userCode,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'User Code / ID'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _userName,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Full Name'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : widget.onRetryAll,
          child: const Text('Retry All'),
        ),
        FilledButton(
          onPressed: _canSubmit
              ? () async {
                  setState(() => _busy = true);
                  try {
                    await widget.onConfirm(
                        _userCode.text.trim(), _userName.text.trim());
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                }
              : null,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Complete Enrollment'),
        ),
      ],
    );
  }
}
