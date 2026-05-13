import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/di/providers.dart';
import '../features/face_verification/presentation/screens/debug_camera_screen.dart';
import '../features/face_verification/presentation/screens/debug_health_screen.dart';
import '../features/face_verification/presentation/screens/enroll_form_screen.dart';
import '../features/face_verification/presentation/screens/home_screen.dart';
import '../features/face_verification/presentation/screens/live_enrollment_screen.dart';
import '../features/face_verification/presentation/screens/permission_screen.dart';
import '../features/face_verification/presentation/screens/security_warning_screen.dart';
import '../features/face_verification/presentation/screens/splash_screen.dart';
import '../features/face_verification/presentation/screens/user_management_screen.dart';
import '../features/face_verification/presentation/screens/verification_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final security = ref.read(securityStatusProvider).valueOrNull;
      final granted = ref.read(cameraPermissionProvider).valueOrNull;
      final path = state.uri.path;

      // While async checks are still resolving, stay on splash.
      if (security == null || granted == null) {
        return path == '/' ? null : '/';
      }
      if (security.isCompromised) {
        return path == '/security' ? null : '/security';
      }
      if (!granted) {
        return path == '/permission' ? null : '/permission';
      }
      // Cleared all gates — leave the splash and forbid going back to gate
      // screens.
      if (path == '/' || path == '/security' || path == '/permission') {
        return '/home';
      }
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SplashScreen()),
      GoRoute(
        path: '/security',
        builder: (_, _) => const SecurityWarningScreen(),
      ),
      GoRoute(
        path: '/permission',
        builder: (_, _) => const PermissionScreen(),
      ),
      GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
      GoRoute(
        path: '/enroll',
        builder: (_, _) => const EnrollFormScreen(),
        routes: [
          GoRoute(
            path: 'live',
            builder: (_, _) => const LiveEnrollmentScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/verify',
        // Custom fast fade in place of Material's default route
        // transition (~250-300 ms slide + fade per audit doc §2.1 stage
        // 2). The verify screen is latency-sensitive — the user already
        // tapped a CTA labelled "Verify Identity" and is staring at the
        // screen waiting for the camera. Material's 300 ms slide is the
        // single largest visible-but-non-pipeline cost on the cold path
        // and is the only stage that runs whether or not prewarm landed.
        // 100 ms fade in / 120 ms fade out: short enough to feel
        // immediate, long enough to read as a deliberate transition
        // (zero-duration looks like a glitch on most platforms). The
        // asymmetric reverse keeps the dismissal feeling controlled
        // rather than abrupt when the user backs out.
        pageBuilder: (context, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          child: const VerificationScreen(),
          transitionDuration: const Duration(milliseconds: 100),
          reverseTransitionDuration: const Duration(milliseconds: 120),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
              ),
              child: child,
            );
          },
        ),
      ),
      GoRoute(
        path: '/manage',
        builder: (_, _) => const UserManagementScreen(),
      ),
      if (kDebugMode)
        GoRoute(
          path: '/debug',
          builder: (_, _) => const DebugCameraScreen(),
          routes: [
            // /debug/health — R5 health page. Snapshot of DB/isolate/
            // permission/security/thresholds/recent-logs for in-field
            // diagnostics. Gated together with /debug under kDebugMode
            // so it never compiles into a release build.
            GoRoute(
              path: 'health',
              builder: (_, _) => const DebugHealthScreen(),
            ),
          ],
        ),
    ],
  );
});
