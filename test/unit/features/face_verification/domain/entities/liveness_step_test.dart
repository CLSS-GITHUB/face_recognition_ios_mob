import 'package:face_ios_android/features/face_verification/domain/entities/liveness_step.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('verifyChallengeOptions', () {
    test('contains exactly four distinct challenges', () {
      // A larger set raises the per-attempt PAD bar (an attacker's
      // canned replay covers at most one option). Four is the current
      // calibration: the four visually unambiguous motions ML Kit can
      // detect reliably on the front camera.
      expect(verifyChallengeOptions, hasLength(4));
      expect(verifyChallengeOptions.toSet(), hasLength(4),
          reason: 'Duplicate options skew the random pick distribution.');
    });

    test('omits the `still` step', () {
      // "Stay still" is not an unpredictable behavioural challenge —
      // a static photo trivially passes it. It must never join the
      // verify-time random pool.
      expect(verifyChallengeOptions, isNot(contains(LivenessStep.still)));
    });

    test('every option is a motion ML Kit can drive verify against', () {
      // blink + mouth-open + turn-left + turn-right are exactly the
      // four observable motions the controller's challenge dispatcher
      // implements. If this set changes, the dispatcher's switch in
      // VerificationController._handleChallenge must update in lockstep.
      expect(
        verifyChallengeOptions,
        containsAll(<LivenessStep>[
          LivenessStep.blink,
          LivenessStep.mouthOpen,
          LivenessStep.turnLeft,
          LivenessStep.turnRight,
        ]),
      );
    });
  });

  group('LivenessStep.isMovement', () {
    // The QualityAssessor relaxes off-axis pose only for movement
    // steps. The controller passes state.challenge to the assessor so
    // turn challenges must report isMovement == true; the others
    // must NOT, or the user could keep their face turned during a
    // blink challenge and still satisfy quality.
    test('turn challenges are movement steps', () {
      expect(LivenessStep.turnLeft.isMovement, isTrue);
      expect(LivenessStep.turnRight.isMovement, isTrue);
    });

    test('non-turn challenges are NOT movement steps', () {
      expect(LivenessStep.blink.isMovement, isFalse);
      expect(LivenessStep.mouthOpen.isMovement, isFalse);
      expect(LivenessStep.still.isMovement, isFalse);
    });
  });
}
