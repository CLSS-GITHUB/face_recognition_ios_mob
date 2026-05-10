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
  bool _initialised = false;

  Future<void> _ensureInitialised() async {
    if (_initialised) return;
    try {
      await _tts.setLanguage(_language);
      // 0.5 = roughly natural; the default is jarringly fast on iOS.
      await _tts.setSpeechRate(0.5);
      // Don't queue — we want the most recent announcement only.
      await _tts.setSharedInstance(true).catchError((_) => true);
      _initialised = true;
    } catch (e, st) {
      _log.warning('TTS init failed; subsequent speak() calls are no-ops', e, st);
      _initialised = true; // give up; don't retry every speak
    }
  }

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
