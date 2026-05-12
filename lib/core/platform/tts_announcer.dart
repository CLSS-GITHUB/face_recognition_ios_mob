import 'package:flutter_tts/flutter_tts.dart';
import 'package:logging/logging.dart';

/// Best-effort spoken-announcement port. The granted-result dialog uses this
/// to read the matched user's name aloud once
/// (architecture_recommendations.md §6.3 / §G3).
///
/// **Best-effort by contract.** TTS engines are unreliable: silent / DnD,
/// missing engine, locale mismatch, etc. Implementations MUST swallow any
/// platform error and log a warning — never throw — so the dialog itself
/// is the canonical surface, and audio is a bonus.
abstract class TtsAnnouncer {
  Future<void> speak(String text);

  /// Wake the underlying TTS engine without producing audible output.
  /// Called when the verify screen first mounts so the first real
  /// `speak()` after a granted match doesn't pay the engine cold-start
  /// cost (~50 ms on most Android builds, more on a cold boot).
  /// Best-effort — same swallow-and-log contract as [speak].
  Future<void> prewarm();

  Future<void> dispose();
}

/// flutter_tts-backed implementation. Configures English by default; locale
/// is left to the system unless the consumer overrides via [language].
class FlutterTtsAnnouncer implements TtsAnnouncer {
  FlutterTtsAnnouncer({String language = 'en-US'})
      : _tts = FlutterTts(),
        _language = language;

  static final Logger _log = Logger('TtsAnnouncer');

  final FlutterTts _tts;
  final String _language;

  /// Cached init future. The bool-flag version of this had a race:
  /// `prewarm()` fires from the verify screen's initState and `speak()`
  /// fires on a granted match. If `speak()` races with an in-flight
  /// prewarm, both observed `_initialised == false` and both fell through
  /// into duplicate `setLanguage / setSpeechRate / setSharedInstance`
  /// platform calls — the speak path then paid the engine cold-start
  /// cost the prewarm was supposed to absorb, defeating O-6.
  ///
  /// Caching the future de-duplicates: concurrent callers await the
  /// same single completion. Stored `Future<void>` is intentionally
  /// `?`-typed so a failed init isn't memoised forever — the catch
  /// inside `_doInit` converts errors into a successful void completion
  /// (we surface failures via the log and degrade to a no-op speak).
  Future<void>? _initFuture;

  Future<void> _ensureInitialised() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    try {
      await _tts.setLanguage(_language);
      // 0.5 = roughly natural; the default is jarringly fast on iOS.
      await _tts.setSpeechRate(0.5);
      // Don't queue — we want the most recent announcement only.
      // `setSharedInstance` is iOS-only; on Android the underlying
      // method-channel call rejects with PlatformException. Swallow.
      await _tts.setSharedInstance(true).catchError((_) => true);
    } catch (e, st) {
      _log.warning(
        'TTS init failed; subsequent speak() calls are no-ops',
        e,
        st,
      );
      // Intentionally don't rethrow — concurrent awaiters see this same
      // resolved future and a follow-up `speak()` will hit the inner
      // try/catch in [speak] without re-attempting init.
    }
  }

  @override
  Future<void> prewarm() => _ensureInitialised();

  @override
  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    await _ensureInitialised();
    try {
      // Flush any in-progress utterance so we always speak the latest name.
      await _tts.stop();
      await _tts.speak(text);
    } catch (e, st) {
      _log.warning('TTS speak failed for "$text"', e, st);
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Ignore — we are tearing down regardless.
    }
  }
}
