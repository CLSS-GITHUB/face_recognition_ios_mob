import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart' as fancy;
import 'package:logging/logging.dart';

/// Bridges the standard `logging` package (used in services / domain code)
/// to a developer-friendly console renderer in debug builds.
///
/// Release builds restrict logs to WARNING and above. See
/// `docs/migration/10_security.md` §10.6 — never log embeddings, names, or
/// similarity scores tied to a user.
void configureLogging() {
  Logger.root.level = kReleaseMode ? Level.WARNING : Level.ALL;
  final dev = fancy.Logger(printer: fancy.PrettyPrinter(methodCount: 0));
  Logger.root.onRecord.listen((rec) {
    final tag = '[${rec.loggerName}] ${rec.message}';
    if (rec.level >= Level.SEVERE) {
      dev.e(tag, error: rec.error, stackTrace: rec.stackTrace);
    } else if (rec.level >= Level.WARNING) {
      dev.w(tag);
    } else if (rec.level >= Level.INFO) {
      dev.i(tag);
    } else {
      dev.d(tag);
    }
  });
}
