import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:logging/logging.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../constants/thresholds.dart';
import '../error/failures.dart';
import '../utils/embedding_sanity.dart';
import '../utils/frame_preparation.dart';

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
    required this.delegateLabel,
  })  : _workerPort = workerPort,
        _isolate = isolate,
        _responsePort = responsePort {
    _subscription = _responsePort.listen(_onResponse);
  }

  /// Human-readable identifier of the TFLite execution path actually in
  /// use. One of `"xnnpack"`, `"cpu"`, `"cpu(xnnpack-validation-fail:…)"`,
  /// `"cpu(xnnpack-construct-fail:…)"`, or `"stub"` in test mode.
  /// Surfaced to /debug/health so a field operator can tell which path
  /// the device ended up on without an interactive debugger.
  final String delegateLabel;

  static const int _bytesExpected =
      FaceThresholds.inputSize * FaceThresholds.inputSize * 3;
  static final Logger _log = Logger('EmbeddingIsolate');

  final SendPort _workerPort;
  final Isolate _isolate;
  final ReceivePort _responsePort;
  late final StreamSubscription<dynamic> _subscription;

  /// Single in-flight slot covering both `extract` (resolves to Float32List)
  /// and `prepare` (resolves to Uint8List). The completer is typed `dynamic`
  /// because the wire protocol dispatches on the worker's reply type — the
  /// public methods above wrap this completer's future in a tightly-typed
  /// `then` chain so callers never see a `dynamic`.
  Completer<dynamic>? _inFlight;
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
    final _IsolateReady readyMsg = initial as _IsolateReady;
    // Surface the selection result on cold-start. Field operators reading
    // `/debug/health` get the same value, but this line is what shows up
    // in `logcat` (and the IDE console) without a UI round-trip.
    //
    // Bypasses both `_log.info` (project's `package:logger` routes via
    // `developer.log`, which only reaches DevTools — never logcat) and
    // `debugPrint` (Flutter throttles to 12 KB/s; the verify
    // controller's per-frame trace already saturates that on a busy
    // run, swallowing this one-shot line).
    // ignore: avoid_print
    print('[EmbeddingIsolate] ready (delegate=${readyMsg.delegateLabel})');

    final responsePort = ReceivePort();
    readyMsg.workerPort.send(_HelloMessage(responsePort.sendPort));

    return EmbeddingIsolate._(
      workerPort: readyMsg.workerPort,
      isolate: isolate,
      responsePort: responsePort,
      delegateLabel: readyMsg.delegateLabel,
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
    final completer = Completer<dynamic>();
    _inFlight = completer;
    final transferable = TransferableTypedData.fromList(<Uint8List>[rgb112]);
    _workerPort.send(_ExtractRequest(transferable));
    return completer.future.then((v) => v as Float32List);
  }

  /// Submits a raw camera frame for the full prepare pipeline
  /// (decode → crop → eye-axis align → resize → flatten) and returns the
  /// 112×112 RGB payload. Phase D moved this off the UI thread to keep the
  /// camera preview smooth during a verify.
  ///
  /// Single-flight against [extract] — the worker's queue length is 1, so
  /// a `prepare` while an extract (or another prepare) is in flight throws
  /// [EmbeddingBusyError].
  Future<Uint8List> prepare({
    required Uint8List rawBytes,
    required int width,
    required int height,
    required RawFrameFormat format,
    required Rect bbox,
    int? leftEyeX,
    int? leftEyeY,
    int? rightEyeX,
    int? rightEyeY,
  }) {
    if (_closed) {
      throw StateError('EmbeddingIsolate is closed');
    }
    if (_inFlight != null) {
      throw const EmbeddingBusyError();
    }
    if (rawBytes.isEmpty || width <= 0 || height <= 0) {
      throw ArgumentError(
        'prepare needs non-empty bytes and positive dimensions; '
        'got bytes=${rawBytes.length}, ${width}x$height',
      );
    }
    final completer = Completer<dynamic>();
    _inFlight = completer;
    final transferable =
        TransferableTypedData.fromList(<Uint8List>[rawBytes]);
    _workerPort.send(_PrepareRequest(
      bytes: transferable,
      width: width,
      height: height,
      formatIndex: format.index,
      bboxLeft: bbox.left,
      bboxTop: bbox.top,
      bboxWidth: bbox.width,
      bboxHeight: bbox.height,
      leftEyeX: leftEyeX,
      leftEyeY: leftEyeY,
      rightEyeX: rightEyeX,
      rightEyeY: rightEyeY,
    ));
    return completer.future.then((v) => v as Uint8List);
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
      // extract reply.
      completer.complete(message);
    } else if (message is Uint8List) {
      // prepare reply — must NOT be coerced into a Float32List view by
      // accident; the caller has already declared the return type via
      // `prepare(...).then((v) => v as Uint8List)`.
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

class _IsolateReady {
  const _IsolateReady(this.workerPort, this.delegateLabel);
  final SendPort workerPort;
  final String delegateLabel;
}

class _HelloMessage {
  const _HelloMessage(this.replyTo);
  final SendPort replyTo;
}

class _ExtractRequest {
  const _ExtractRequest(this.bytes);
  final TransferableTypedData bytes;
}

class _PrepareRequest {
  const _PrepareRequest({
    required this.bytes,
    required this.width,
    required this.height,
    required this.formatIndex,
    required this.bboxLeft,
    required this.bboxTop,
    required this.bboxWidth,
    required this.bboxHeight,
    this.leftEyeX,
    this.leftEyeY,
    this.rightEyeX,
    this.rightEyeY,
  });
  final TransferableTypedData bytes;
  final int width;
  final int height;
  final int formatIndex;
  final double bboxLeft;
  final double bboxTop;
  final double bboxWidth;
  final double bboxHeight;
  final int? leftEyeX;
  final int? leftEyeY;
  final int? rightEyeX;
  final int? rightEyeY;
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
  // Pre-allocate the TFLite I/O buffers ONCE at isolate startup and
  // reuse on every extract. The 1×112×112×3 nested-list input is ~150 KB
  // of `double`s; rebuilding it per frame allocated ~6 ms / extract on a
  // Pixel 6 (architecture §8). We overwrite the slots in-place inside
  // `_runTfliteInto`. The startup validation step in `_selectInterpreter`
  // reuses these same buffers, so the "first real frame" cost is the
  // same whether or not XNNPACK is in play.
  final reusableInput = _allocInputBuffer();
  final reusableOutput = _allocOutputBuffer();

  Interpreter? interpreter;
  Delegate? delegate;
  String delegateLabel = 'stub';

  if (args.config.useTflite) {
    final result = _selectInterpreter(
      args.config.modelBytes,
      reusableInput,
      reusableOutput,
    );
    if (result.failure != null) {
      args.replyTo.send(_IsolateInitFailure(result.failure!));
      return;
    }
    interpreter = result.interpreter;
    delegate = result.delegate;
    delegateLabel = result.label;
  }

  final inbox = ReceivePort();
  args.replyTo.send(_IsolateReady(inbox.sendPort, delegateLabel));

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
      if (msg is _PrepareRequest && host != null) {
        try {
          if (args.config.stubLatency > Duration.zero) {
            await Future<void>.delayed(args.config.stubLatency);
          }
          final raw = msg.bytes.materialize().asUint8List();
          final format = RawFrameFormat.values[msg.formatIndex];
          final prepared = FramePreparation.prepare(
            rawBytes: raw,
            width: msg.width,
            height: msg.height,
            format: format,
            bbox: Rect.fromLTWH(
              msg.bboxLeft,
              msg.bboxTop,
              msg.bboxWidth,
              msg.bboxHeight,
            ),
            leftEyeX: msg.leftEyeX,
            leftEyeY: msg.leftEyeY,
            rightEyeX: msg.rightEyeX,
            rightEyeY: msg.rightEyeY,
          );
          if (prepared == null) {
            host.send(_ExtractFailure(
              'FramePreparation.prepare returned null '
              '(bytes=${raw.length}, ${msg.width}x${msg.height}, '
              'format=${format.name})',
              StackTrace.current,
            ));
          } else {
            host.send(prepared);
          }
        } catch (e, st) {
          host.send(_ExtractFailure(e.toString(), st));
        }
      }
    }
  } finally {
    // Order matters: close the interpreter BEFORE deleting the delegate
    // so the native handle has no live references to a delegate that's
    // already been torn down. `Delegate.delete` is best-effort — if the
    // wrapper was already nulled out by the interpreter's close path
    // we'd rather log-and-continue than crash the shutdown sequence.
    interpreter?.close();
    if (delegate != null) {
      try {
        delegate.delete();
      } catch (_) {
        // Already deleted by the interpreter's close path. Fine.
      }
    }
    inbox.close();
  }
}

/// Result of the startup interpreter-selection step: either an
/// initialised interpreter (with optional delegate) plus a label, or a
/// failure reason that the host turns into an
/// [EmbeddingIsolateUnavailableError].
class _SelectionResult {
  _SelectionResult.success({
    required this.interpreter,
    required this.delegate,
    required this.label,
  }) : failure = null;
  _SelectionResult.failure(this.failure)
      : interpreter = null,
        delegate = null,
        label = '';

  final Interpreter? interpreter;
  final Delegate? delegate;
  final String label;
  final String? failure;
}

/// Builds the live interpreter for this isolate, preferring XNNPACK and
/// falling back to plain CPU when the delegate either won't construct or
/// disagrees with the CPU reference on a deterministic test vector.
///
/// XNNPACK is well-behaved for FP32 dense ops on every modern ARM chip,
/// but the only way to be *sure* an enrolled template (extracted by CPU
/// pre-upgrade) and a probe (extracted by XNNPACK post-upgrade) end up
/// in the same feature space is to compare outputs on the same input.
/// We require cosine ≥ 0.999 — a few ulps of FP drift is fine, a wrong
/// op-fusion that flips an axis is not.
_SelectionResult _selectInterpreter(
  Uint8List modelBytes,
  List<List<List<List<double>>>> reusableInput,
  List<List<double>> reusableOutput,
) {
  // 1. Baseline CPU interpreter — also validates model output shape.
  Interpreter cpu;
  try {
    final opts = InterpreterOptions()
      ..threads = FaceThresholds.tfliteThreads;
    cpu = Interpreter.fromBuffer(modelBytes, options: opts);
  } catch (e) {
    return _SelectionResult.failure('Interpreter.fromBuffer failed: $e');
  }

  // Output-tensor shape check. Catches "wrong .tflite dropped into
  // assets/models/" at startup instead of letting the matcher silently
  // score against the wrong feature space.
  try {
    final outShape = cpu.getOutputTensor(0).shape;
    final ok = outShape.length == 2 &&
        outShape[0] == 1 &&
        outShape[1] == FaceThresholds.embeddingDim;
    if (!ok) {
      cpu.close();
      return _SelectionResult.failure(
        'Model output shape $outShape does not match expected '
        '[1, ${FaceThresholds.embeddingDim}]. Update '
        'FaceThresholds.embeddingDim / modelVersion before shipping '
        'this model.',
      );
    }
  } catch (e) {
    cpu.close();
    return _SelectionResult.failure(
      'Output-tensor shape inspection failed: $e',
    );
  }

  // 2. CPU golden — captured on a deterministic ramp. The bytes don't
  //    have to be face-like; we're only checking the delegate output
  //    agrees with CPU pixel-by-pixel of the same input.
  final testBytes = _validationTestBytes();
  Float32List goldenCpu;
  try {
    goldenCpu = _runTfliteInto(
      cpu,
      testBytes,
      reusableInput,
      reusableOutput,
    );
  } catch (e) {
    cpu.close();
    return _SelectionResult.failure('CPU golden inference failed: $e');
  }

  // 3. Try delegates in order of expected speed: GPU (Android only) →
  //    XNNPACK → plain CPU. Each trial reuses the same CPU golden and
  //    the cosine ≥ 0.999 gate; failures get folded into the label so
  //    /debug/health tells the field operator which path won.
  final failures = <String>[];

  // 3a. GPU (Android only). tflite_flutter exposes GpuDelegateV2 which
  //     wraps the OpenGL/OpenCL backend. Default options use FP32
  //     (`isPrecisionLossAllowed: false`); we let the validation gate
  //     reject any device whose driver flips an axis under FP16 fusion.
  //     On iOS this path is skipped — the GPU backend there is Metal /
  //     CoreML and routes through a different setter on
  //     InterpreterOptions (out of scope for this commit).
  if (Platform.isAndroid) {
    final gpuTrial = _tryDelegate(
      modelBytes: modelBytes,
      goldenCpu: goldenCpu,
      testBytes: testBytes,
      reusableInput: reusableInput,
      reusableOutput: reusableOutput,
      name: 'gpu',
      buildDelegate: () => GpuDelegateV2(),
    );
    if (gpuTrial.success) {
      cpu.close();
      return _SelectionResult.success(
        interpreter: gpuTrial.interpreter!,
        delegate: gpuTrial.delegate,
        label: 'gpu',
      );
    }
    failures.add(gpuTrial.failureReason!);
  }

  // 3b. XNNPACK. CPU SIMD path; well-behaved on essentially every ARM
  //     chip. ~8–12 ms / extract win over plain CPU; no precision risk.
  final xnnTrial = _tryDelegate(
    modelBytes: modelBytes,
    goldenCpu: goldenCpu,
    testBytes: testBytes,
    reusableInput: reusableInput,
    reusableOutput: reusableOutput,
    name: 'xnnpack',
    buildDelegate: () => XNNPackDelegate(
      options: XNNPackDelegateOptions(
        numThreads: FaceThresholds.tfliteThreads,
      ),
    ),
  );
  if (xnnTrial.success) {
    cpu.close();
    final label = failures.isEmpty
        ? 'xnnpack'
        : 'xnnpack(after:${failures.join('|')})';
    return _SelectionResult.success(
      interpreter: xnnTrial.interpreter!,
      delegate: xnnTrial.delegate,
      label: label,
    );
  }
  failures.add(xnnTrial.failureReason!);

  // 3c. Both delegates failed. Keep the validation CPU as the live
  //     interpreter and report every failure so the field can decide
  //     whether it's a vendor-driver issue (GPU) or a model/op-fusion
  //     issue (XNNPACK).
  return _SelectionResult.success(
    interpreter: cpu,
    delegate: null,
    label: 'cpu(${failures.join('|')})',
  );
}

/// Outcome of a single delegate trial: a constructed-and-validated
/// interpreter/delegate pair, or a structured failure reason that gets
/// folded into the [_SelectionResult]'s label.
class _DelegateTrialResult {
  _DelegateTrialResult.success(this.interpreter, this.delegate)
      : failureReason = null;
  _DelegateTrialResult.failure(this.failureReason)
      : interpreter = null,
        delegate = null;

  final Interpreter? interpreter;
  final Delegate? delegate;
  final String? failureReason;

  bool get success => interpreter != null;
}

/// Builds an interpreter with [buildDelegate], runs [testBytes] through
/// it, and compares the L2-normalised result to [goldenCpu]. Returns a
/// success result when cosine ≥ 0.999, otherwise tears the delegate
/// down and returns a failure with the observed similarity (or the
/// construct-time exception). Used identically for every entry on the
/// delegate ladder so the safety contract is uniform.
_DelegateTrialResult _tryDelegate({
  required Uint8List modelBytes,
  required Float32List goldenCpu,
  required Uint8List testBytes,
  required List<List<List<List<double>>>> reusableInput,
  required List<List<double>> reusableOutput,
  required String name,
  required Delegate Function() buildDelegate,
}) {
  Delegate? delegate;
  Interpreter? interp;
  try {
    delegate = buildDelegate();
    final opts = InterpreterOptions()
      ..threads = FaceThresholds.tfliteThreads
      ..addDelegate(delegate);
    interp = Interpreter.fromBuffer(modelBytes, options: opts);
  } catch (e) {
    try {
      delegate?.delete();
    } catch (_) {}
    return _DelegateTrialResult.failure('$name-construct-fail:$e');
  }

  Float32List output;
  try {
    output = _runTfliteInto(interp, testBytes, reusableInput, reusableOutput);
  } catch (e) {
    interp.close();
    try {
      delegate.delete();
    } catch (_) {}
    return _DelegateTrialResult.failure('$name-infer-fail:$e');
  }

  final sim = _cosineL2Normalised(goldenCpu, output);
  if (sim >= 0.999) {
    return _DelegateTrialResult.success(interp, delegate);
  }

  interp.close();
  try {
    delegate.delete();
  } catch (_) {}
  return _DelegateTrialResult.failure(
    '$name-validation-fail:${sim.toStringAsFixed(4)}',
  );
}

/// Cosine similarity over two L2-normalised vectors — same length is a
/// precondition (the model output dim is fixed). Reduces to a dot
/// product; no extra sqrt or norm needed.
double _cosineL2Normalised(Float32List a, Float32List b) {
  if (a.length != b.length) return 0;
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

/// Deterministic ramp pattern used at startup to compare CPU vs delegate
/// output. Same bytes every time so the validation is reproducible across
/// runs and across devices.
Uint8List _validationTestBytes() {
  const n = FaceThresholds.inputSize * FaceThresholds.inputSize * 3;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = i & 0xff;
  }
  return out;
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
  // otherwise mutate the slot underneath it). EmbeddingSanity throws on
  // NaN/Inf/degenerate-magnitude — those reach the host as
  // EmbeddingFailedError and the verify-log records `extractionFailed`,
  // not a regular `noMatch` (which a silent zero-cosine fallback would
  // have masked).
  return EmbeddingSanity.sanitizeAndNormalize(
    Float32List.fromList(output[0]),
  );
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
  return EmbeddingSanity.sanitizeAndNormalize(acc);
}
