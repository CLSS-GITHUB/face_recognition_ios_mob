import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/action_card.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              scheme.surface,
              scheme.primaryContainer.withValues(alpha: 0.3),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 48),
                Container(
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.fingerprint_rounded,
                    size: 80,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 48),
                Text(
                  'Face Verification',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                ),
                Text(
                  'Secure On-Device Authentication',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: scheme.secondary,
                      ),
                ),
                const SizedBox(height: 64),
                ActionCard(
                  title: 'Enroll New Face',
                  subtitle: 'Register your identity',
                  icon: Icons.person_add_rounded,
                  containerColor: scheme.primaryContainer,
                  contentColor: scheme.onPrimaryContainer,
                  onTap: () => context.push('/enroll'),
                ),
                const SizedBox(height: 16),
                ActionCard(
                  title: 'Verify Identity',
                  subtitle: 'Quick face matching',
                  icon: Icons.face_rounded,
                  containerColor: scheme.secondaryContainer,
                  contentColor: scheme.onSecondaryContainer,
                  onTap: () => context.push('/verify'),
                ),
                const SizedBox(height: 16),
                ActionCard(
                  title: 'Manage Users',
                  subtitle: 'Active/Delete records',
                  icon: Icons.groups_rounded,
                  containerColor: scheme.tertiaryContainer,
                  contentColor: scheme.onTertiaryContainer,
                  onTap: () => context.push('/manage'),
                ),
                if (kDebugMode) ...[
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () => context.push('/debug'),
                    icon: const Icon(Icons.bug_report_outlined),
                    label: const Text('Phase 2 debug harness'),
                  ),
                ],
                const SizedBox(height: 48),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
