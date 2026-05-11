import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'pending_enrollment.dart';

class EnrollFormScreen extends StatefulWidget {
  const EnrollFormScreen({super.key});

  @override
  State<EnrollFormScreen> createState() => _EnrollFormScreenState();
}

class _EnrollFormScreenState extends State<EnrollFormScreen> {
  final _userCode = TextEditingController();
  final _userName = TextEditingController();

  /// User self-reports whether they're wearing glasses RIGHT NOW.
  /// Stamped into the captured template's metadata so a complementary
  /// re-enrol (opposite state, same userId) builds a multi-template
  /// user whose recognition is robust across both glasses states.
  /// Defaults to false — the common case is bare-face enrolment.
  bool _wearsGlasses = false;

  @override
  void dispose() {
    _userCode.dispose();
    _userName.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      _userCode.text.trim().isNotEmpty && _userName.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Face Enrollment'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enroll an Employee',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Secure live enrollment ensures your identity is verified correctly.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _userCode,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Employee ID / Code',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _userName,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Employee Full Name',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              // Glasses self-report. Stamps into the template's
              // metadata so a later opposite-state re-enrol (same
              // userId) builds a multi-template user covering both
              // states. The matcher picks the closest template per
              // user at verify time — no explicit branching needed.
              SwitchListTile.adaptive(
                value: _wearsGlasses,
                onChanged: (v) => setState(() => _wearsGlasses = v),
                contentPadding: EdgeInsets.zero,
                title: const Text("I'm wearing glasses right now"),
                subtitle: Text(
                  'For best recognition, re-enroll later with the '
                  'opposite state — both captures are stored under the '
                  'same employee.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  onPressed: _canSubmit
                      ? () => context.push(
                            '/enroll/live',
                            extra: PendingEnrollment(
                              userCode: _userCode.text.trim(),
                              userName: _userName.text.trim(),
                              wearsGlasses: _wearsGlasses,
                            ),
                          )
                      : null,
                  icon: const Icon(Icons.add_a_photo),
                  label: const Text('Live Camera Enrollment'),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
