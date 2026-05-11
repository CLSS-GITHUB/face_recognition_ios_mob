/// Order matches LivenessDetector.kt exactly:
/// BLINK → MOUTH_OPEN → TURN_LEFT → TURN_RIGHT → STILL.
enum LivenessStep {
  blink,
  mouthOpen,
  turnLeft,
  turnRight,
  still;

  /// Human-readable label used by InstructionCard (mirrors Compose copy).
  String get instruction => switch (this) {
        LivenessStep.blink => 'Blink your eyes',
        LivenessStep.mouthOpen => 'Open your mouth',
        LivenessStep.turnLeft => 'Turn head to the Left',
        LivenessStep.turnRight => 'Turn head to the Right',
        LivenessStep.still => 'Center your face',
      };

  bool get isMovement =>
      this == LivenessStep.turnLeft || this == LivenessStep.turnRight;
}

/// Liveness challenges eligible for selection on the Verify Identity
/// screen. One is picked uniformly at random per attempt to defeat
/// canned-replay videos — a single recorded clip can satisfy at most
/// one of these. `still` is omitted because "stay still" is not a
/// challenge an attacker has to perform (a static photo trivially
/// passes it); the other steps each require an unpredictable, observable
/// motion. Order does not matter; pick with secure random.
const List<LivenessStep> verifyChallengeOptions = <LivenessStep>[
  LivenessStep.blink,
  LivenessStep.mouthOpen,
  LivenessStep.turnLeft,
  LivenessStep.turnRight,
];
