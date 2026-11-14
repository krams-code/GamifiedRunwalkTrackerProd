import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/models/activity_model.dart';
import 'package:hakbanghero/models/run_mode.dart';
import 'package:hakbanghero/widgets/live_tracker_animation.dart';
import 'package:hakbanghero/widgets/session_views.dart';
import 'package:hakbanghero/widgets/block_ui.dart';

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

  final run = ActivitySession(id: 'run', type: ActivityType.run, userPick: ActivityType.run,
    startTime: DateTime(2026, 11, 14), endTime: DateTime(2026, 11, 14, 0, 20),
    distanceKm: 2, durationSeconds: 1200, avgSpeedKmh: 6, maxSpeedKmh: 12,
    xpEarned: 239, coinsEarned: 16);

  for (final size in [const Size(320, 568), const Size(360, 640), const Size(390, 844)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('run and summary fit $size with text scale $scale and safe insets', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Widget host(Widget child) => MaterialApp(home: MediaQuery(
          data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale),
            padding: const EdgeInsets.only(top: 24, bottom: 24)),
          child: Scaffold(body: child),
        ));
        await tester.pumpWidget(host(TrackingView(type: ActivityType.run, time: '20:00',
          speedKmh: 6, moving: true, distanceKm: 2, pace: "10'00\"", maxSpeedKmh: 12,
          mode: kNovice, gpsStatus: 1, onFinish: () {})));
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.byType(LiveTrackerAnimation), findsOneWidget);
        expect(find.text('DISTANCE'), findsOneWidget);
        expect(find.text('AVG PACE'), findsOneWidget);
        expect(find.text('MAX SPEED'), findsOneWidget);
        if (scale == 1) {
          final heights = ['DISTANCE', 'AVG PACE', 'MAX SPEED'].map((label) =>
            tester.getSize(find.ancestor(of: find.text(label), matching: find.byType(Block)).first).height).toList();
          expect(heights[0], heights[1]);
          expect(heights[1], heights[2]);
        }
        expect(tester.takeException(), isNull);
        var done = false, next = false;
        final unlocked = size.width == 320 && scale == 2;
        await tester.pumpWidget(host(SessionSummarySheet(session: run, isSaving: false,
          completedQuests: const [], mode: kNovice, awardedXp: 239, awardedCoins: 16,
          unlockedRank: unlocked ? kVanguard : null, onNextRank: () => next = true,
          onDone: () => done = true)));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Share'), findsOneWidget);
        expect(find.text('Save Image'), findsOneWidget);
        final share = find.ancestor(of: find.text('Share'), matching: find.byType(PressBlock)).first;
        expect(tester.widget<PressBlock>(share).onTap, isNull,
          reason: 'Export stays disabled without a confirmed saved-run reference.');
        expect(tester.getSize(share).height, greaterThanOrEqualTo(48));
        if (unlocked) {
          final rankButton = find.text('NEXT RANK: ${kVanguard.name}');
          await tester.ensureVisible(rankButton);
          await tester.tap(rankButton);
          await tester.pump();
          expect(next, isTrue);
        }
        final button = find.text('DONE');
        if (scale > 1.5) {
          await tester.ensureVisible(button);
        }
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(size.height - 24));
        await tester.tap(button);
        await tester.pump();
        expect(done, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
