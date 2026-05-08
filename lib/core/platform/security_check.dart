import 'package:safe_device/safe_device.dart';

/// Result of a device-integrity check. Mirrors `SecurityUtils.kt` semantics:
/// the app refuses to run when either flag is true.
class SecurityStatus {
  const SecurityStatus({required this.rooted, required this.emulator});

  final bool rooted;
  final bool emulator;

  bool get isCompromised => rooted || emulator;
}

class SecurityCheck {
  const SecurityCheck();

  Future<SecurityStatus> evaluate() async {
    final rooted = await SafeDevice.isJailBroken;
    final isReal = await SafeDevice.isRealDevice;
    return SecurityStatus(rooted: rooted, emulator: !isReal);
  }
}
