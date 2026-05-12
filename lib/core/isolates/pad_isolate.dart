import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
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

/// Output-tensor contract for the bundled PAD checkpoint.
///
/// The wire protocol PAD exposes to the verify controller is a single
/// scalar spoof score in `[0, 1]`. The checkpoint's actual output
/// tensor shape varies by model family, so the isolate picks a reducer
/// at spawn time based on this hint plus the probed output shape:
///
/// - [singleSigmoidScalar] — `[1, 1]` float, already in `[0, 1]`.
///   Passthrough (clamped). Common for one-shot binary heads.
/// - [binarySoftmax] — `[1, 2]` logits in `(real, spoof)` order.
///   Softmaxed; spoof = `p[1]`.
/// - [silentFaceThree] — `[1, 3]` logits in Silent-Face's
///   `(spoof_print, real, spoof_replay)` order (MiniFASNetV1SE /
///   MiniFASNetV2 convention from github.com/minivision-ai/Silent-Face-
///   Anti-Spoofing). Softmaxed; spoof = `1 - p[1]`.
///
/// If your checkpoint outputs `(spoof, real)` instead of `(real, spoof)`
/// for the two-class case, the production wiring needs to be widened —
/// don't silently flip [binarySoftmax]'s semantics. PAD is the gate of
/// last resort and getting the polarity backwards turns a deny-gate
/// into an allow-gate.
enum PadModelKind {
  singleSigmoidScalar,
  binarySoftmax,
  silentFaceThree,
}

/// Pixel-normalisation strategy applied inside the isolate before
/// inference. The wrong choice tanks accuracy without throwing — the
/// model still produces a "spoof score", just an unreliable one.
///
/// - [signedHalf] — `(px - 127.5) / 127.5`, the convention shared with
///   the embedding extractor in `EmbeddingIsolate`.
/// - [unitZeroOne] — `px / 255.0`. Simple unit normalisation. Many
///   PyTorch-exported checkpoints land here.
/// - [imagenet] — per-channel `((px / 255) - mean) / std` with the
///   ImageNet statistics (R/G/B mean 0.485/0.456/0.406; std
///   0.229/0.224/0.225). Silent-Face's MiniFASNet was trained on this
///   pipeline.
enum PadNormalization {
  signedHalf,
  unitZeroOne,
  imagenet,
}

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
/// Caller's input contract: a 112×112 RGB byte buffer
/// ([`FaceThresholds.inputSize`]² × 3 = 37 632 bytes). The isolate
/// resizes bilinearly to the model's native input H×W at spawn-probed
/// size, applies the configured [PadNormalization], runs inference,
/// and reduces the output to a scalar via the configured
/// [PadModelKind]. Both decisions are baked at spawn so the hot path
/// stays branch-light.
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

  /// Identifier surfaced to `/debug/health`. `"stub"` in test mode;
  /// in production carries the full contract — e.g.
  /// `"tflite(80x80x3 → [1,3], kind=silentFaceThree, norm=imagenet)"`
  /// — so a field operator reading the health screen can verify the
  /// live model is the one calibrated for.
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
  ///
  /// [kind] selects the output reducer; [normalization] selects the
  /// pixel preprocessing. Both default to the Silent-Face-Anti-
  /// Spoofing reference (audit doc §9.4). Overridable from the
  /// provider for a checkpoint with a different contract.
  static Future<PadIsolate> spawn({
    PadModelKind kind = PadModelKind.silentFaceThree,
    PadNormalization normalization = PadNormalization.imagenet,
  }) async {
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
    return _spawnWithConfig(_PadConfig.tflite(modelBytes, kind, normalization));
  }

  /// Test-only entry point. The worker uses a deterministic stub
  /// scorer (always [fixedScore], clamped to `[0, 1]`) so tests can
  /// exercise the wire protocol without the asset. The stub does NOT
  /// touch any TFLite code path; shape probing, resize, and reducer
  /// logic are covered by their pure-Dart unit tests instead.
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
//  Pure helpers — exported for unit tests via @visibleForTesting wrappers.
// ---------------------------------------------------------------------------

/// Reduce the TFLite output tensor to a scalar spoof score in `[0, 1]`.
///
/// [output] is the raw output buffer as written by `Interpreter.run`,
/// shaped `[1, n]` where `n` depends on [kind]:
///   - [PadModelKind.singleSigmoidScalar] → `n=1`, clamped passthrough.
///   - [PadModelKind.binarySoftmax]       → `n=2`, softmax then `p[1]`.
///   - [PadModelKind.silentFaceThree]     → `n=3`, softmax then `1 - p[1]`.
///
/// Result is clamped to `[0, 1]` so a numerically-degenerate
/// passthrough can never push the verify controller's threshold check
/// into UB.
@visibleForTesting
double reduceToSpoofScore(List<List<double>> output, PadModelKind kind) {
  final row = output[0];
  switch (kind) {
    case PadModelKind.singleSigmoidScalar:
      return row[0].clamp(0.0, 1.0).toDouble();
    case PadModelKind.binarySoftmax:
      final p = _softmax(row);
      return p[1].clamp(0.0, 1.0).toDouble();
    case PadModelKind.silentFaceThree:
      final p = _softmax(row);
      return (1.0 - p[1]).clamp(0.0, 1.0).toDouble();
  }
}

/// Numerically-stable softmax. Subtract the max before exp to avoid
/// overflow on large logits — PAD heads frequently emit values in the
/// ±20 range when very confident.
List<double> _softmax(List<double> logits) {
  var maxLogit = logits[0];
  for (var i = 1; i < logits.length; i++) {
    if (logits[i] > maxLogit) maxLogit = logits[i];
  }
  final out = List<double>.filled(logits.length, 0);
  var sum = 0.0;
  for (var i = 0; i < logits.length; i++) {
    final e = math.exp(logits[i] - maxLogit);
    out[i] = e;
    sum += e;
  }
  if (sum == 0) {
    // All inputs were -inf or NaN. Return a uniform distribution so
    // downstream reducers stay in-range.
    final uniform = 1.0 / logits.length;
    for (var i = 0; i < out.length; i++) {
      out[i] = uniform;
    }
    return out;
  }
  for (var i = 0; i < out.length; i++) {
    out[i] /= sum;
  }
  return out;
}

/// Bilinear-resize the source 112×112 RGB buffer into a destination
/// `dstSize × dstSize` square of floats, applying [normalization] in
/// the same pass. `dst` is the pre-allocated `[1, dstSize, dstSize, 3]`
/// buffer. Resize is skipped (single-pass write) when the destination
/// matches the source size.
///
/// Bilinear (not nearest) because PAD heads key on texture / Moiré /
/// micro-gradient cues — nearest-neighbour aliases those out and
/// systematically biases the model toward "real".
@visibleForTesting
void resizeAndNormalize(
  Uint8List src,
  int srcSize,
  List<List<List<List<double>>>> dst,
  int dstSize,
  PadNormalization normalization,
) {
  if (dstSize == srcSize) {
    _writeNormalized(src, dst, dstSize, normalization);
    return;
  }
  // Sample positions in the source space. We use the half-pixel
  // convention so the resized image is centred — `(0.5 + i) * scale -
  // 0.5` — matching PIL.Image.BILINEAR which Silent-Face's training
  // pipeline uses.
  final scale = srcSize / dstSize;
  final plane0 = dst[0];
  for (var y = 0; y < dstSize; y++) {
    final sy = (0.5 + y) * scale - 0.5;
    final y0 = sy.floor().clamp(0, srcSize - 1);
    final y1 = (y0 + 1).clamp(0, srcSize - 1);
    final wy = (sy - y0).clamp(0.0, 1.0);
    final row = plane0[y];
    for (var x = 0; x < dstSize; x++) {
      final sx = (0.5 + x) * scale - 0.5;
      final x0 = sx.floor().clamp(0, srcSize - 1);
      final x1 = (x0 + 1).clamp(0, srcSize - 1);
      final wx = (sx - x0).clamp(0.0, 1.0);
      final px = row[x];
      for (var c = 0; c < 3; c++) {
        final p00 = src[(y0 * srcSize + x0) * 3 + c].toDouble();
        final p01 = src[(y0 * srcSize + x1) * 3 + c].toDouble();
        final p10 = src[(y1 * srcSize + x0) * 3 + c].toDouble();
        final p11 = src[(y1 * srcSize + x1) * 3 + c].toDouble();
        final top = p00 + (p01 - p00) * wx;
        final bot = p10 + (p11 - p10) * wx;
        final blended = top + (bot - top) * wy;
        px[c] = _normalizePixel(blended, c, normalization);
      }
    }
  }
}

void _writeNormalized(
  Uint8List src,
  List<List<List<List<double>>>> dst,
  int n,
  PadNormalization normalization,
) {
  final plane0 = dst[0];
  var p = 0;
  for (var y = 0; y < n; y++) {
    final row = plane0[y];
    for (var x = 0; x < n; x++) {
      final px = row[x];
      px[0] = _normalizePixel(src[p++].toDouble(), 0, normalization);
      px[1] = _normalizePixel(src[p++].toDouble(), 1, normalization);
      px[2] = _normalizePixel(src[p++].toDouble(), 2, normalization);
    }
  }
}

const List<double> _imagenetMean = <double>[0.485, 0.456, 0.406];
const List<double> _imagenetStd = <double>[0.229, 0.224, 0.225];

double _normalizePixel(double v, int channel, PadNormalization norm) {
  switch (norm) {
    case PadNormalization.signedHalf:
      return (v - FaceThresholds.pixelMean) / FaceThresholds.pixelMean;
    case PadNormalization.unitZeroOne:
      return v / 255.0;
    case PadNormalization.imagenet:
      return ((v / 255.0) - _imagenetMean[channel]) / _imagenetStd[channel];
  }
}

int _expectedOutputLen(PadModelKind kind) {
  switch (kind) {
    case PadModelKind.singleSigmoidScalar:
      return 1;
    case PadModelKind.binarySoftmax:
      return 2;
    case PadModelKind.silentFaceThree:
      return 3;
  }
}

String _kindLabel(PadModelKind kind) {
  switch (kind) {
    case PadModelKind.singleSigmoidScalar:
      return 'singleSigmoidScalar';
    case PadModelKind.binarySoftmax:
      return 'binarySoftmax';
    case PadModelKind.silentFaceThree:
      return 'silentFaceThree';
  }
}

String _normLabel(PadNormalization norm) {
  switch (norm) {
    case PadNormalization.signedHalf:
      return 'signedHalf';
    case PadNormalization.unitZeroOne:
      return 'unitZeroOne';
    case PadNormalization.imagenet:
      return 'imagenet';
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
    required this.kind,
    required this.normalization,
    required this.stubLatency,
    required this.stubScore,
  });
  factory _PadConfig.tflite(
    Uint8List bytes,
    PadModelKind kind,
    PadNormalization normalization,
  ) =>
      _PadConfig._(
        useTflite: true,
        modelBytes: bytes,
        kind: kind,
        normalization: normalization,
        stubLatency: Duration.zero,
        stubScore: 0.0,
      );
  factory _PadConfig.stub(Duration latency, double score) => _PadConfig._(
        useTflite: false,
        modelBytes: Uint8List(0),
        kind: PadModelKind.singleSigmoidScalar,
        normalization: PadNormalization.signedHalf,
        stubLatency: latency,
        stubScore: score,
      );

  final bool useTflite;
  final Uint8List modelBytes;
  final PadModelKind kind;
  final PadNormalization normalization;
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
  int inputSize = FaceThresholds.inputSize;
  List<List<List<List<double>>>> reusableInput =
      _allocInputBuffer(FaceThresholds.inputSize);
  List<List<double>> reusableOutput = _allocOutputBuffer(1);

  if (args.config.useTflite) {
    try {
      final opts = InterpreterOptions()
        ..threads = FaceThresholds.tfliteThreads;
      interpreter =
          Interpreter.fromBuffer(args.config.modelBytes, options: opts);

      // Probe the model's input shape. Expect [1, H, W, 3] with H == W
      // and channels == 3. Anything else means the caller bundled a
      // checkpoint whose contract this code path doesn't yet handle.
      final inShape = interpreter.getInputTensor(0).shape;
      if (inShape.length != 4 ||
          inShape[0] != 1 ||
          inShape[3] != 3 ||
          inShape[1] != inShape[2] ||
          inShape[1] <= 0) {
        args.replyTo.send(_PadInitFailure(
          'Unsupported PAD input shape $inShape — expected [1, N, N, 3]',
        ));
        return;
      }
      inputSize = inShape[1];

      // Probe the output shape and check it matches the configured
      // kind. Reject mismatch up-front rather than silently returning
      // a wrong-polarity score.
      final outShape = interpreter.getOutputTensor(0).shape;
      final expected = _expectedOutputLen(args.config.kind);
      if (outShape.length != 2 || outShape[0] != 1 || outShape[1] != expected) {
        args.replyTo.send(_PadInitFailure(
          'PAD output shape $outShape does not match '
          'kind=${_kindLabel(args.config.kind)} (expected [1, $expected])',
        ));
        return;
      }

      reusableInput = _allocInputBuffer(inputSize);
      reusableOutput = _allocOutputBuffer(expected);

      modelLabel = 'tflite(${inputSize}x${inputSize}x3 → '
          '[1,$expected], kind=${_kindLabel(args.config.kind)}, '
          'norm=${_normLabel(args.config.normalization)})';
    } catch (e) {
      args.replyTo.send(_PadInitFailure('Interpreter.fromBuffer failed: $e'));
      return;
    }
  }

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
              inputSize,
              args.config.kind,
              args.config.normalization,
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

List<List<List<List<double>>>> _allocInputBuffer(int n) {
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

List<List<double>> _allocOutputBuffer(int n) {
  return <List<double>>[List<double>.filled(n, 0)];
}

double _runTfliteInto(
  Interpreter interp,
  Uint8List rgb,
  List<List<List<List<double>>>> input,
  List<List<double>> output,
  int modelInputSize,
  PadModelKind kind,
  PadNormalization normalization,
) {
  resizeAndNormalize(
    rgb,
    FaceThresholds.inputSize,
    input,
    modelInputSize,
    normalization,
  );
  interp.run(input, output);
  return reduceToSpoofScore(output, kind);
}
