import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:hakbanghero/widgets/hero_rig.dart';
import 'package:hakbanghero/widgets/live_tracker_animation.dart';

class _Auth extends FirebaseAuthPlatform {
  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => this;
  @override
  FirebaseAuthPlatform setInitialValues({PigeonUserDetails? currentUser, String? languageCode}) => this;
  @override
  UserPlatform? get currentUser => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  FirebaseAuthPlatform.instance = _Auth();
  setUpAll(() async => Firebase.initializeApp());

  test('motion stays within 1.00 to 1.025 with no abrupt response to noisy speed', () {
    final pulse = RunScenePulse();
    var previous = pulse.scale;
    var maximum = 1.0;
    for (var i = 0; i < 1200; i++) {
      final speed = i < 600 ? 12.0 : (i.isEven ? 4.9 : 10.1);
      pulse.advance(0.016, speedKmh: speed);
      expect(pulse.scale, inInclusiveRange(1.0, 1.025));
      expect((pulse.scale - previous).abs(), lessThan(0.004));
      if (pulse.scale > maximum) maximum = pulse.scale;
      previous = pulse.scale;
    }
    expect(maximum, greaterThan(1.02));
  });

  test('stopping and pausing settle to exactly normal scale within 450 ms', () {
    for (final paused in [false, true]) {
      final pulse = RunScenePulse();
      for (var i = 0; i < 100; i++) {
        pulse.advance(0.016, speedKmh: 12);
      }
      for (var i = 0; i < 30; i++) {
        pulse.advance(0.016, speedKmh: paused ? 12 : 0, paused: paused, boost: true);
      }
      expect(pulse.scale, 1.0);
    }
  });

  test('missing or invalid motion remains static even during a challenge', () {
    for (final speed in [0.0, -1.0, double.nan, double.infinity]) {
      final pulse = RunScenePulse();
      for (var i = 0; i < 100; i++) {
        pulse.advance(0.016, speedKmh: speed, boost: true);
      }
      expect(pulse.scale, 1);
      expect(runStateForSpeed(speed), RunState.idle);
    }
  });

  test('scene cadence uses the existing character periods', () {
    expect(rigPeriodForPose(RigPose.walk).inMilliseconds, 900);
    expect(rigPeriodForPose(RigPose.jog).inMilliseconds, 640);
    expect(rigPeriodForPose(RigPose.run).inMilliseconds, 440);
  });

  testWidgets('the scene scales about the feet without horizontal translation', (tester) async {
    Widget scene({bool paused = false}) => MaterialApp(home: Scaffold(body: Center(
      child: SizedBox(width: 320, height: 260, child: LiveTrackerAnimation(
        currentUserSpeedKmh: 12, paused: paused,
        avatarData: const {'hero_id': 'sprout', 'gender': 'male', 'body_tier': 'normal'},
      )),
    )));
    await tester.pumpWidget(scene());
    final zoom = find.byKey(const ValueKey('run-scene-zoom'));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final transform = tester.widget<Transform>(zoom);
      expect(transform.transform.entry(0, 0), inInclusiveRange(1.0, 1.025));
      expect(transform.transform.entry(0, 3), 0);
      expect(transform.alignment, isA<Alignment>());
    }
    final anchor = tester.widget<Transform>(zoom).alignment! as Alignment;
    expect(anchor.x, 0);
    expect(anchor.y, greaterThan(0.8));
    await tester.pumpWidget(scene(paused: true));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.widget<Transform>(zoom).transform.entry(0, 0), 1.0);
    expect(find.descendant(of: zoom, matching: find.text('⏸ PAUSED')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
