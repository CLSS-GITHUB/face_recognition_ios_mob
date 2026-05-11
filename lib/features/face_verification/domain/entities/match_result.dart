/// (index, similarity) pair returned by FaceMatchingService.findBestMatch.
/// Mirrors `Pair<Int, Float>` in NativeFaceMatcher.kt.
class MatchResult {
  const MatchResult({required this.index, required this.similarity});
  const MatchResult.none()
      : index = -1,
        similarity = -2.0;

  final int index;
  final double similarity;

  bool get isMatch => index != -1;
}

/// Open-set best-user match used by the verify use case.
///
/// `userIndex` points into the unique-users list of the flat template
/// bank (NOT the per-template slot). `bestSimilarity` is the best
/// cosine across **all** of that user's templates; `runnerUpSimilarity`
/// is the same quantity for the second-best user (or `-1.0` when only
/// one user is enrolled). The caller enforces an open-set margin check
/// — see `FaceThresholds.verifyUserMargin`.
class UserMatchResult {
  const UserMatchResult({
    required this.userIndex,
    required this.bestSimilarity,
    required this.runnerUpSimilarity,
  });

  const UserMatchResult.none()
      : userIndex = -1,
        bestSimilarity = -2.0,
        runnerUpSimilarity = -2.0;

  final int userIndex;
  final double bestSimilarity;
  final double runnerUpSimilarity;

  bool get hasResult => userIndex != -1;

  /// Gap between the winning user and the runner-up. Used as the
  /// open-set safety margin in `VerifyUser`.
  double get margin => bestSimilarity - runnerUpSimilarity;
}
