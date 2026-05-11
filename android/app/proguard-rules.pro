# R8 / ProGuard rules for the release build. Without these, R8 in full
# mode (the default since AGP 8) fails the build on tflite_flutter's
# compile-time reference to the optional GPU delegate, even though we
# never link the GPU native lib.

# ----- TensorFlow Lite (tflite_flutter) ---------------------------------
# Keep every TFLite class — the package uses JNI-style native bindings
# and reflective lookups for delegates. Minification has rarely (if
# ever) helped here and the cost of getting it wrong is a runtime
# crash on first inference.
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.** { *; }
# The GPU + NNAPI delegates aren't pulled in by our pubspec, but their
# classes are referenced from tflite_flutter's facade. R8 full mode
# treats those references as fatal unless we silence them.
-dontwarn org.tensorflow.lite.gpu.**
-dontwarn org.tensorflow.lite.nnapi.**
-dontwarn org.tensorflow.**

# ----- ML Kit face detection -------------------------------------------
# ML Kit ships its model loader behind reflective class lookups. Keep
# both the public facade and the bundled-model internals so the on-
# device detector resolves at runtime.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_face.** { *; }
-dontwarn com.google.mlkit.**

# ----- camera plugin (Flutter) -----------------------------------------
-keep class io.flutter.plugins.camera.** { *; }

# ----- sensors_plus ----------------------------------------------------
# Sensor event listener subclasses are reflectively bound.
-keep class dev.fluttercommunity.plus.sensors.** { *; }

# ----- drift / sqlite3_flutter_libs ------------------------------------
# Drift codegen produces deeply nested classes; safest to leave them
# alone since the package is JNI-heavy.
-keep class com.simolus.drift.** { *; }
-keep class org.sqlite.** { *; }
-dontwarn org.sqlite.**
