import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/di/providers.dart';

/// Resolves security + permission state and forwards to the appropriate
/// destination. Equivalent to MainActivity's `LaunchedEffect(Unit)` block.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Cold-start maintenance: drop verification_log rows older than
      // FaceThresholds.verificationLogRetentionDays. Fire-and-forget —
      // routing must never wait on the sweep.
      ref.read(verificationLogPurgeProvider.future).ignore();
      _route();
    });
  }

  Future<void> _route() async {
    final security = await ref.read(securityStatusProvider.future);
    if (!mounted) return;
    if (security.isCompromised) {
      context.go('/security');
      return;
    }
    final granted = await ref.read(cameraPermissionProvider.future);
    if (!mounted) return;
    context.go(granted ? '/home' : '/permission');
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
