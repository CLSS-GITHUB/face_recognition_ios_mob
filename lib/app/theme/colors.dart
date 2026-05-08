import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  // Seed color used for Material 3 ColorScheme generation.
  // Adjust to match the Android Color.kt palette once it's confirmed.
  static const Color seed = Color(0xFF1E5AC8);

  // Status colors used in InstructionCard and UserCard pills.
  static const Color success = Color(0xFF4CAF50);
  static const Color successBg = Color(0xFFE8F5E9);
  static const Color successFg = Color(0xFF2E7D32);
  static const Color dangerBg = Color(0xFFFFEBEE);
  static const Color dangerFg = Color(0xFFC62828);

  // CircularProgressSegments active/inactive colors from Android.
  static const Color progressActive = Color(0xFF2962FF);
  static const Color progressInactive = Color(0xFFD8E2FF);
}
