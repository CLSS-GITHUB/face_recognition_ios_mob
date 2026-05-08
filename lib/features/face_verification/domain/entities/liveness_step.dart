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
