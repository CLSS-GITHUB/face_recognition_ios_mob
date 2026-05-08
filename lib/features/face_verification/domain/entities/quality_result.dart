/// Output of QualityAssessor.assess(). Mirrors QualityAssessor.kt's
/// `QualityResult(isGood, issues)`.
class QualityResult {
  const QualityResult({required this.isGood, required this.issues});
  const QualityResult.ok() : isGood = true, issues = const [];
  const QualityResult.failed(this.issues) : isGood = false;

  final bool isGood;
  final List<String> issues;
}
