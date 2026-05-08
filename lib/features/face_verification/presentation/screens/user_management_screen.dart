import 'package:flutter/material.dart';

/// Phase 1 placeholder. Real implementation lands in Phase 3 (Item #24 in
/// `docs/migration/12_effort_estimation.md`).
class UserManagementScreen extends StatelessWidget {
  const UserManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Enrolled Users')),
      body: const Center(child: Text('User management — Phase 3')),
    );
  }
}
