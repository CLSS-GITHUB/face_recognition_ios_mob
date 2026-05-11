import 'dart:async';

/// Test config picked up by `flutter_test` for any test under `test/`.
///
/// Goldens are compared against `test/golden/goldens/` files generated on
/// the CI runner (Linux). Local devs regenerate by passing
/// `--update-goldens` to `flutter test`. Other-platform divergences are
/// expected — only the CI artefact is canonical.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Default font fallback Flutter 3.41 ships works fine for our tests; no
  // bespoke font loading needed.
  await testMain();
}
