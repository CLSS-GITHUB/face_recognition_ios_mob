import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:logging/logging.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../constants/thresholds.dart';
import '../error/failures.dart';

/// Asset path the production isolate will try to load. **No file is
/// shipped under this path today.** Drop a vetted MIT/Apache/BSD-3
/// `.tflite` checkpoint here and the `padClassifierProvider` will
/// switch from `NoOpPadClassifier` to this isolate automatically (when
/// `--dart-define=PAD_ENABLED=true`).
///
/// Reference checkpoint (audit doc §9.4):
/// `github.com/minivision-ai/Silent-Face-Anti-Spoofing`. The provenance
/// audit + calibration study described in the analysis doc must
/// complete before this is set live in a customer build.
const String _padModelAsset = 'assets/models/pad.tflite';

/// Long-lived isolate for the passive PAD (Presentation Attack
/// Detection) classifier. Mirrors `EmbeddingIsolate`'s lifecycle and
/// wire-protocol shape — single-flight queue, TransferableTypedData
/// payloads, structured init failures — but exposes a smaller surface:
/// one `classify(rgb)` call returning a single spoof score in `[0, 1]`.
///
/// **Scaffold-only today.** Until a vetted PAD checkpoint is added to
/// the bundle, `PadIsolate.spawn()` will throw
/// [PadUnavailableError] at the `rootBundle.load` step and the
/// production wiring will fall back to `NoOpPadClassifier`. The stub
/// `spawnTestStub()` path lets unit tests exercise the wire protocol
/// without the asset.
///
/// Model contract this scaffold currently assumes:
///   - Input: `[1, 112, 112, 3]` float32 RGB, same preprocessing as
///     `EmbeddingIsolate` (`(pixel - 127.5) / 127.5`). Re-tune when a
///     real model with a different input shape lands.
///   - Output: `[1, 1]` float32 — interpreted as spoof score. A model
///     that outputs `[1, 2]` (real, spoof) softmax must be adapted at
///     `_runClassify` so the contract stays scalar.
class PadIsolate {
  PadIsolate._({
    required SendPort workerPort,
    required Isolate isolate,
    required ReceivePort responsePort,
    required this.modelLabel,
  })  : _workerPort = workerPort,
        _isolate = isolate,
        _responsePort = responsePort {
    _subscription = _responsePort.listen(_onResponse);
  }

  /// Identifier surfaced to `/debug/health`. `"stub"` in test mode,
  /// `"silent-face-anti-spoofing-v1"` (or similar) when a real model
  /// loads — the live wiring should match the checkpoint's name.
  final String modelLabel;

  static const int _bytesExpected =
      FaceThresholds.inputSize * FaceThresholds.inputSize * 3;
  static final Logger _log = Logger('PadIsolate');

  final SendPort _workerPort;
  final Isolate _isolate;
  final ReceivePort _responsePort;
  late final StreamSubscription<dynamic> _subscription;

  Completer<double>? _inFlight;
  bool _closed = false;

  /// Production entry point. Throws [PadUnavailableError] if the
  /// checkpoint isn't bundled OR the spawn fails — the caller is
  /// expected to map this to "fall back to NoOpPadClassifier" so the
  /// verify pipeline degrades gracefully.
  static Future<PadIsolate> spawn() async {
    Uint8List modelBytes;
    try {
      final asset = await rootBundle.load(_padModelAsset);
      modelBytes =
          asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
    } catch (e, st) {
      _log.warning(
        'PAD checkpoint not bundled at $_padModelAsset — '
        'PAD pipeline will not spawn. Falling back to NoOpPadClassifier.',
        e,
        st,
      );
      throw PadUnavailableError('PAD checkpoint missing: $e');
    }
    return _spawnWithConfig(_PadConfig.tflite(modelBytes));
  }

  /// Test-only entry point. The worker uses a deterministic stub
  /// scorer (always `0.0`, the live-face verdict) so tests can
  /// exercise the wire protocol without the asset.
  @visibleForTesting
  static Future<PadIsolate> spawnTestStub({
    Duration latency = Duration.zero,
    double fixedScore = 0.0,
  }) {
    return _spawnWithConfig(_PadConfig.stub(latency, fixedScore));
  }

  static Future<PadIsolate> _spawnWithConfig(_PadConfig config) async {
    final ready = ReceivePort();
    Isolate isolate;
    try {
      isolate = await Isolate.spawn<_PadSpawnArgs>(
        _isolateMain,
        _PadSpawnArgs(ready.sendPort, config),
        debugName: 'PadIsolate',
        errorsAreFatal: true,
      );
    } catch (e, st) {
      ready.close();
      _log.severe('PadIsolate.spawn failed', e, st);
      throw PadUnavailableError('Isolate.spawn failed: $e');
    }

    final initial = await ready.first;
    ready.close();
    if (initial is _PadInitFailure) {
      isolate.kill(priority: Isolate.immediate);
      throw PadUnavailableError(initial.reason);
    }
    final _PadReady readyMsg = initial as _PadReady;

    final responsePort = ReceivePort();
    readyMsg.workerPort.send(_PadHello(responsePort.sendPort));

    return PadIsolate._(
      workerPort: readyMsg.workerPort,
      isolate: isolate,
      responsePort: responsePort,
      modelLabel: readyMsg.modelLabel,
    );
  }

  /// Submits one 112×112 RGB buffer for spoof scoring. Single-flight —
  /// a second classify before the first resolves throws.
  Future<double> classify(Uint8List rgb112) {
    if (_closed) {
      throw StateError('PadIsolate is closed');
    }
    if (_inFlight != null) {
      throw const PadUnavailableError(
        'PAD isolate is busy with a previous classify',
      );
    }
    if (rgb112.length != _bytesExpected) {
      throw ArgumentError(
        'PAD expects $_bytesExpected bytes (RGB '
        '${FaceThresholds.inputSize}×${FaceThresholds.inputSize}); '
        'got ${rgb112.length}',
      );
    }
    final completer = Completer<double>();
    _inFlight = completer;
    final transferable = TransferableTypedData.fromList(<Uint8List>[rgb112]);
    _workerPort.send(_PadClassifyRequest(transferable));
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _workerPort.send(const _PadCloseMessage());
    await _subscription.cancel();
    _responsePort.close();
    _isolate.kill(priority: Isolate.immediate);
    final pending = _inFlight;
    _inFlight = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        StateError('PadIsolate closed mid-classify'),
      );
    }
  }

  void _onResponse(dynamic message) {
    final completer = _inFlight;
    _inFlight = null;
    if (completer == null) return;
    if (message is double) {
      completer.complete(message);
    } else if (message is _PadClassifyFailure) {
      completer.completeError(
        PadUnavailableError('classify failed: ${message.reason}'),
        message.stackTrace,
      );
    } else {
      completer.completeError(
        StateError('Unexpected PAD worker message: ${message.runtimeType}'),
      );
    }
  }
}

// ---------------------------------------------------------------------------
//  Wire types
// ---------------------------------------------------------------------------

class _PadSpawnArgs {
  const _PadSpawnArgs(this.replyTo, this.config);
  final SendPort replyTo;
  final _PadConfig config;
}

class _PadConfig {
  const _PadConfig._({
    required this.useTflite,
    required this.modelBytes,
    required this.stubLatency,
    required this.stubScore,
  });
  factory _PadConfig.tflite(Uint8List bytes) => _PadConfig._(
        useTflite: true,
        modelBytes: bytes,
        stubLatency: Duration.zero,
        stubScore: 0.0,
      );
  factory _PadConfig.stub(Duration latency, double score) => _PadConfig._(
        useTflite: false,
        modelBytes: Uint8List(0),
        stubLatency: latency,
        stubScore: score,
      );

  final bool useTflite;
  final Uint8List modelBytes;
  final Duration stubLatency;
  final double stubScore;
}

class _PadInitFailure {
  const _PadInitFailure(this.reason);
  final String reason;
}

class _PadReady {
  const _PadReady(this.workerPort, this.modelLabel);
  final SendPort workerPort;
  final String modelLabel;
}

class _PadHello {
  const _PadHello(this.replyTo);
  final SendPort replyTo;
}

class _PadClassifyRequest {
  const _PadClassifyRequest(this.bytes);
  final TransferableTypedData bytes;
}

class _PadCloseMessage {
  const _PadCloseMessage();
}

class _PadClassifyFailure {
  const _PadClassifyFailure(this.reason, this.stackTrace);
  final String reason;
  final StackTrace stackTrace;
}

// ---------------------------------------------------------------------------
//  Isolate entry point
// ---------------------------------------------------------------------------

Future<void> _isolateMain(_PadSpawnArgs args) async {
  Interpreter? interpreter;
  String modelLabel = 'stub';

  if (args.config.useTflite) {
    try {
      final opts = InterpreterOptions()
        ..threads = FaceThresholds.tfliteThreads;
      interpreter = Interpreter.fromBuffer(args.config.modelBytes, options: opts);
      // Pin the label from the buffer's first few bytes as a fingerprint;
      // a real wiring would carry the model name from the asset manifest.
      modelLabel = 'tflite(bytes=${args.config.modelBytes.length})';
    } catch (e) {
      args.replyTo.send(_PadInitFailure('Interpreter.fromBuffer failed: $e'));
      return;
    }
  }

  final reusableInput = _allocInputBuffer();
  final reusableOutput = _allocOutputBuffer();

  final inbox = ReceivePort();
  args.replyTo.send(_PadReady(inbox.sendPort, modelLabel));

  SendPort? host;
  try {
    await for (final dynamic msg in inbox) {
      if (msg is _PadHello) {
        host = msg.replyTo;
        continue;
      }
      if (msg is _PadCloseMessage) {
        return;
      }
      if (msg is _PadClassifyRequest && host != null) {
        try {
          final bytes = msg.bytes.materialize().asUint8List();
          double score;
          if (args.config.useTflite) {
            score = _runTfliteInto(
              interpreter!,
              bytes,
              reusableInput,
              reusableOutput,
            );
          } else {
            if (args.config.stubLatency > Duration.zero) {
              await Future<void>.delayed(args.config.stubLatency);
            }
            score = args.config.stubScore;
          }
          host.send(score.clamp(0.0, 1.0));
        } catch (e, st) {
          host.send(_PadClassifyFailure(e.toString(), st));
        }
      }
    }
  } finally {
    interpreter?.close();
    inbox.close();
  }
}

List<List<List<List<double>>>> _allocInputBuffer() {
  final n = FaceThresholds.inputSize;
  return List<List<List<List<double>>>>.generate(
    1,
    (_) => List<List<List<double>>>.generate(
      n,
      (_) => List<List<double>>.generate(
        n,
        (_) => List<double>.filled(3, 0),
      ),
    ),
  );
}

List<List<double>> _allocOutputBuffer() {
  // Single-scalar output assumed. Adapt when a real model with a
  // different output shape lands (e.g. softmax over [real, spoof]).
  return <List<double>>[<double>[0]];
}

double _runTfliteInto(
  Interpreter interp,
  Uint8List rgb,
  List<List<List<List<double>>>> input,
  List<List<double>> output,
) {
  final n = FaceThresholds.inputSize;
  final mean = FaceThresholds.pixelMean;
  var p = 0;
  for (var y = 0; y < n; y++) {
    final row = input[0][y];
    for (var x = 0; x < n; x++) {
      final px = row[x];
      px[0] = (rgb[p++] - mean) / mean;
      px[1] = (rgb[p++] - mean) / mean;
      px[2] = (rgb[p++] - mean) / mean;
    }
  }
  interp.run(input, output);
  return output[0][0];
}
