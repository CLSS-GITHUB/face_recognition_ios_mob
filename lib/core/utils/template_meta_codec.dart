import 'dart:typed_data';

import '../constants/thresholds.dart';

/// Per-template metadata that lives alongside the encrypted embedding
/// blob. The matching pipeline only needs the embedding vector, but the
/// **enrolment** flow benefits from knowing *the context in which a
/// template was captured* — most importantly whether the user was
/// wearing eyeglasses at capture time, since that lets a single user
/// have multiple templates (glasses-on + glasses-off) and lets the
/// matcher pick whichever is closest at verify time without an explicit
/// "are they wearing glasses now?" classifier.
///
/// Indexed 1-to-1 with [User.faceTemplates]: `templateMeta[i]` describes
/// `faceTemplates[i]`. When the lists go out of sync (e.g. a user
/// migrated up from a schema that didn't track this), the entity treats
/// missing entries as `wearsGlasses=false` defaults — see [User].
class FaceTemplateMeta {
  const FaceTemplateMeta({
    required this.wearsGlasses,
    required this.capturedAt,
  });

  /// True when the user *was* wearing eyeglasses at the moment this
  /// template was extracted. The verify matcher does not branch on this
  /// directly — it picks the highest-cosine template per user — but
  /// telemetry / re-enrol UX can use it to surface "you have a
  /// glasses-off template but no glasses-on template" prompts.
  final bool wearsGlasses;

  /// Wall-clock (UTC) at which the template was extracted. Distinct
  /// from `User.lastEnrolledAt`, which is the most recent timestamp
  /// across the whole user — this is per-template.
  final DateTime capturedAt;

  FaceTemplateMeta copyWith({bool? wearsGlasses, DateTime? capturedAt}) {
    return FaceTemplateMeta(
      wearsGlasses: wearsGlasses ?? this.wearsGlasses,
      capturedAt: capturedAt ?? this.capturedAt,
    );
  }
}

/// Binary codec for the [FaceTemplateMeta] list. Same wire-style as
/// `FaceTemplatesCodec`: little-endian, length-prefixed. Each entry is
/// exactly 9 bytes (1 flag byte + 8 ms-since-epoch int64), so the total
/// blob is `4 + 9*n` bytes and is cheap to round-trip.
///
/// Layout:
///   [int32 count]
///   for each meta:
///     [int8  flags]        bit 0 = wearsGlasses
///     [int64 capturedAtMs] millis since epoch, UTC
///
/// On corruption (bad count, truncated body) decoding returns whatever
/// was successfully parsed up to the bad row, matching the
/// FaceTemplatesCodec "break on bad row" contract.
class FaceTemplateMetaCodec {
  FaceTemplateMetaCodec._();

  static const int _entryBytes = 9;
  static const int _flagWearsGlasses = 1 << 0;

  /// Empty payload — used as the encrypted default when a user has no
  /// metadata yet (e.g. legacy rows migrated from a pre-templateMeta
  /// schema). Encrypts cleanly through `TemplateCrypto`.
  static final Uint8List empty = Uint8List.fromList(<int>[0, 0, 0, 0]);

  static Uint8List encode(List<FaceTemplateMeta> metas) {
    final out = ByteData(4 + metas.length * _entryBytes);
    out.setInt32(0, metas.length, Endian.little);
    var off = 4;
    for (final m in metas) {
      out.setInt8(off, m.wearsGlasses ? _flagWearsGlasses : 0);
      out.setInt64(
        off + 1,
        m.capturedAt.toUtc().millisecondsSinceEpoch,
        Endian.little,
      );
      off += _entryBytes;
    }
    return out.buffer.asUint8List();
  }

  static List<FaceTemplateMeta> decode(Uint8List blob) {
    if (blob.length < 4) return const <FaceTemplateMeta>[];
    final data = ByteData.sublistView(blob);
    final n = data.getInt32(0, Endian.little);
    // Sanity bounds — the per-user template cap also bounds the meta
    // list. Negative / absurd counts indicate a corrupt blob.
    if (n < 0 || n > FaceThresholds.maxTemplatesPerUser) {
      return const <FaceTemplateMeta>[];
    }
    final out = <FaceTemplateMeta>[];
    var off = 4;
    for (var i = 0; i < n; i++) {
      if (blob.length - off < _entryBytes) break;
      final flags = data.getInt8(off);
      final ms = data.getInt64(off + 1, Endian.little);
      out.add(FaceTemplateMeta(
        wearsGlasses: (flags & _flagWearsGlasses) != 0,
        capturedAt: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
      ));
      off += _entryBytes;
    }
    return out;
  }
}
