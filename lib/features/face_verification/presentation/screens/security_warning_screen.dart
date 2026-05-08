import 'package:flutter/material.dart';

class SecurityWarningScreen extends StatelessWidget {
  const SecurityWarningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.errorContainer,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.security_rounded, size: 120, color: scheme.error),
              const SizedBox(height: 32),
              Text(
                'Security Risk Detected',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'This application cannot run on rooted devices or emulators '
                'for security reasons.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
