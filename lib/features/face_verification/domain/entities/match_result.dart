/// (index, similarity) pair returned by FaceMatchingService.findBestMatch.
/// Mirrors `Pair<Int, Float>` in NativeFaceMatcher.kt.
class MatchResult {
  const MatchResult({required this.index, required this.similarity});
  const MatchResult.none() : index = -1, similarity = -2.0;

  final int index;
  final double similarity;

  bool get isMatch => index != -1;
}
