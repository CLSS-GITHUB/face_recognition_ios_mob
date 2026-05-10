import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:logging/logging.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../constants/thresholds.dart';
import '../error/failures.dart';

const String _modelAsset = 'assets/models/mobile_facenet.tflite';

/// Long-lived isolate that owns the MobileFaceNet TFLite interpreter.
///
/// Architecture: see `docs/verification/architecture_recommendations.md` §3.3.
///
/// Wire schema (host ↔ isolate):
/// - Host → isolate: `TransferableTypedData` containing exactly
///   `inputSize × inputSize × 3` RGB bytes (37,632 bytes for 112×112).
/// - Isolate → host: `Float32List(192)` — the L2-normalised embedding.
/// - On failure inside the isolate the reply is an [_ExtractFailure] payload;
///   the host completer is errored with [EmbeddingFailedError].
/// - Close: the host sends [_CloseMessage]; the isolate disposes the
///   interpreter, closes its receive port, and exits.
///
/// Concurrency: at most one extract is in flight (queue length 1). A second
/// `extract` while the first is unresolved throws [EmbeddingBusyError]; the
/// in-flight call is **not** cancelled.
class EmbeddingIsolate {
  EmbeddingIsolate._({
    required SendPort workerPort,
    required Isolate isolate,
    required ReceivePort responsePort,
  })  : _workerPort = workerPort,
        _isolate = isolate,
        _responsePort = responsePort {
    _subscription = _responsePort.listen(_onResponse);
  }

  static const int _bytesExpected =
      FaceThresholds.inputSize * FaceThresholds.inputSize * 3;
  static final Logger _log = Logger('EmbeddingIsolate');

  final SendPort _workerPort;
  final Isolate _isolate;
  final ReceivePort _responsePort;
  late final StreamSubscription<dynamic> _subscription;

  Completer<Float32List>? _inFlight;
  bool _closed = false;

  /// Production entry point: loads the bundled TFLite asset on the host
  /// isolate and hands the bytes off to the worker. Typically wired through
  /// a `keepAlive` Riverpod provider so the spawn cost is paid once.
  static Future<EmbeddingIsolate> spawn() async {
    try {
      final modelData = await rootBundle.load(_modelAsset);
      final modelBytes = modelData.buffer
          .asUint8List(modelData.offsetInBytes, modelData.lengthInBytes);
      return spawnWithBytes(modelBytes);
    } catch (e, st) {
      _log.severe('Failed to load TFLite model bytes', e, st);
      throw EmbeddingIsolateUnavailableError(
        'Failed to load model asset: $e',
      );
    }
  }

  /// Lower-level entry point used by `spawn` and any caller that wants to
  /// supply pre-loaded model bytes (e.g. an integration test that ships a
  /// fixture model).
  static Future<EmbeddingIsolate> spawnWithBytes(Uint8List modelBytes) {
    return _spawnWithConfig(_IsolateConfig.tflite(modelBytes));
  }

  /// Test-only entry point. The worker uses a deterministic stub embedder
  /// (see [_stubEmbed]) instead of TFLite, so unit tests can exercise the
  /// isolate plumbing without the native interpreter or asset bundle.
  @visibleForTesting
  static Future<EmbeddingIsolate> spawnTestStub({
    Duration latency = Duration.zero,
  }) {
    return _spawnWithConfig(_IsolateConfig.stub(latency));
  }

  static Future<EmbeddingIsolate> _spawnWithConfig(
    _IsolateConfig config,
  ) async {
    final ready = ReceivePort();
    Isolate isolate;
    try {
      isolate = await Isolate.spawn<_SpawnArgs>(
        _isolateMain,
        _SpawnArgs(ready.sendPort, config),
        debugName: 'EmbeddingIsolate',
        errorsAreFatal: true,
      );
    } catch (e, st) {
      ready.close();
      _log.severe('Isolate.spawn failed', e, st);
      throw EmbeddingIsolateUnavailableError('Isolate.spawn failed: $e');
    }

    final initial = await ready.first;
    ready.close();
    if (initial is _IsolateInitFailure) {
      isolate.kill(priority: Isolate.immediate);
      throw EmbeddingIsolateUnavailableError(initial.reason);
    }
    final SendPort workerPort = initial as SendPort;

    final responsePort = ReceivePort();
    workerPort.send(_HelloMessage(responsePort.sendPort));

    return EmbeddingIsolate._(
      workerPort: workerPort,
      isolate: isolate,
      responsePort: responsePort,
    );
  }

  /// Submits one frame for embedding. Throws [EmbeddingBusyError] if a
  /// previous extract is still in flight, [ArgumentError] if `rgb112` does
  /// not contain exactly `inputSize × inputSize × 3` bytes, [StateError] if
  /// the isolate has been closed, and [EmbeddingFailedError] if the worker
  /// reports inference failure.
  Future<Float32List> extract(Uint8List rgb112) {
    if (_closed) {
      throw StateError('EmbeddingIsolate is closed');
    }
    if (_inFlight != null) {
      throw const EmbeddingBusyError();
    }
    if (rgb112.length != _bytesExpected) {
      throw ArgumentError(
        'Expected $_bytesExpected bytes (RGB ${FaceThresholds.inputSize}×'
        '${FaceThresholds.inputSize}), got ${rgb112.length}',
      );
    }
    final completer = Completer<Float32List>();
    _inFlight = completer;
    final transferable = TransferableTypedData.fromList(<Uint8List>[rgb112]);
    _workerPort.send(_ExtractRequest(transferable));
    return completer.future;
  }

  /// Disposes the worker. Pending extract (if any) errors with [StateError].
  /// Idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _workerPort.send(const _CloseMessage());
    await _subscription.cancel();
    _responsePort.close();
    _isolate.kill(priority: Isolate.immediate);
    final pending = _inFlight;
    _inFlight = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        StateError('EmbeddingIsolate closed mid-extract'),
      );
    }
  }

  void _onResponse(dynamic message) {
    final completer = _inFlight;
    _inFlight = null;
    if (completer == null) return;

    if (message is Float32List) {
      completer.complete(message);
    } else if (message is _ExtractFailure) {
      completer.completeError(const EmbeddingFailedError(), message.stackTrace);
    } else {
      completer.completeError(
        StateError('Unexpected message from worker: ${message.runtimeType}'),
      );
    }
  }
}

// ---------------------------------------------------------------------------
//  Wire types
// ---------------------------------------------------------------------------

class _SpawnArgs {
  const _SpawnArgs(this.replyTo, this.config);
  final SendPort replyTo;
  final _IsolateConfig config;
}

class _IsolateConfig {
  const _IsolateConfig._({
    required this.useTflite,
    required this.modelBytes,
    required this.stubLatency,
  });
  factory _IsolateConfig.tflite(Uint8List bytes) => _IsolateConfig._(
        useTflite: true,
        modelBytes: bytes,
        stubLatency: Duration.zero,
      );
  factory _IsolateConfig.stub(Duration latency) => _IsolateConfig._(
        useTflite: false,
        modelBytes: Uint8List(0),
        stubLatency: latency,
      );

  final bool useTflite;
  final Uint8List modelBytes;
  final Duration stubLatency;
}

class _IsolateInitFailure {
  const _IsolateInitFailure(this.reason);
  final String reason;
}

class _HelloMessage {
  const _HelloMessage(this.replyTo);
  final SendPort replyTo;
}

class _ExtractRequest {
  const _ExtractRequest(this.bytes);
  final TransferableTypedData bytes;
}

class _CloseMessage {
  const _CloseMessage();
}

class _ExtractFailure {
  const _ExtractFailure(this.reason, this.stackTrace);
  final String reason;
  final StackTrace stackTrace;
}

// ---------------------------------------------------------------------------
//  Isolate entry point
// ---------------------------------------------------------------------------

Future<void> _isolateMain(_SpawnArgs args) async {
  Interpreter? interpreter;
  if (args.config.useTflite) {
    try {
      final options = InterpreterOptions()
        ..threads = FaceThresholds.tfliteThreads;
      interpreter = Interpreter.fromBuffer(
        args.config.modelBytes,
        options: options,
      );
    } catch (e) {
      args.replyTo.send(
        _IsolateInitFailure('Interpreter.fromBuffer failed: $e'),
      );
      return;
    }
  }

  // Pre-allocate the TFLite I/O buffers ONCE at isolate startup and
  // reuse on every extract. The 1×112×112×3 nested-list input is ~150 KB
  // of `double`s; rebuilding it per frame allocated ~6 ms / extract on a
  // Pixel 6 (architecture §8). We overwrite the slots in-place inside
  // `_runTfliteInto`.
  final reusableInput = _allocInputBuffer();
  final reusableOutput = _allocOutputBuffer();

  final inbox = ReceivePort();
  args.replyTo.send(inbox.sendPort);

  // ReceivePort is a single-subscription stream — we must do all reads
  // through one `await for`. The first message is expected to be the
  // host's `_HelloMessage`; subsequent messages are extract requests or
  // close, processed strictly serially (queue length 1).
  SendPort? host;
  try {
    await for (final dynamic msg in inbox) {
      if (msg is _HelloMessage) {
        host = msg.replyTo;
        continue;
      }
      if (msg is _CloseMessage) {
        return;
      }
      if (msg is _ExtractRequest && host != null) {
        try {
          final bytes = msg.bytes.materialize().asUint8List();
          Float32List result;
          if (args.config.useTflite) {
            result = _runTfliteInto(
              interpreter!,
              bytes,
              reusableInput,
              reusableOutput,
            );
          } else {
            if (args.config.stubLatency > Duration.zero) {
              await Future<void>.delayed(args.config.stubLatency);
            }
            result = _stubEmbed(bytes);
          }
          host.send(result);
        } catch (e, st) {
          host.send(_ExtractFailure(e.toString(), st));
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
  // 1×N×N×3 nested-list — the only shape tflite_flutter accepts.
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
  return List<List<double>>.generate(
    1,
    (_) => List<double>.filled(FaceThresholds.embeddingDim, 0),
  );
}

/// In-place fill of [input] from `rgb`, run the interpreter into [output],
/// then return the L2-normalised result. The caller owns both buffers and
/// reuses them across extracts.
Float32List _runTfliteInto(
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
  // The output list is reused; copy the bytes off into a fresh Float32List
  // so the host receives an independent payload (the next extract would
  // otherwise mutate the slot underneath it).
  return _l2(Float32List.fromList(output[0]));
}

/// Deterministic stub embedder for unit tests. Sums the input bytes into 192
/// buckets and L2-normalises the result. NOT a face embedding — just enough
/// structure to verify wire integrity (round-trips) and that the same input
/// produces the same output.
Float32List _stubEmbed(Uint8List rgb) {
  const dim = FaceThresholds.embeddingDim;
  final acc = Float32List(dim);
  for (var i = 0; i < rgb.length; i++) {
    acc[i % dim] += rgb[i].toDouble();
  }
  return _l2(acc);
}

Float32List _l2(Float32List v) {
  var sumSq = 0.0;
  for (var i = 0; i < v.length; i++) {
    sumSq += v[i] * v[i];
  }
  final norm = sqrt(sumSq);
  if (norm < 1e-6) return v;
  final out = Float32List(v.length);
  for (var i = 0; i < v.length; i++) {
    out[i] = v[i] / norm;
  }
  return out;
}
