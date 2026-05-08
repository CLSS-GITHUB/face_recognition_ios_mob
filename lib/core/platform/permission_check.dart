import 'package:permission_handler/permission_handler.dart';

class PermissionCheck {
  const PermissionCheck();

  Future<bool> isCameraGranted() async {
    final status = await Permission.camera.status;
    return status.isGranted;
  }

  Future<bool> requestCamera() async {
    final status = await Permission.camera.request();
    return status.isGranted;
  }
}
