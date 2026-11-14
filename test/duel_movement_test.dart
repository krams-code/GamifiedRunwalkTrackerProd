import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/models/duel_policy.dart';
import 'package:hakbanghero/services/duel_movement.dart';

void main() {
  final start = DateTime.utc(2026, 11, 14);
  DuelFix fix(int second, double meters, {double accuracy = 1, bool mocked = false}) =>
      DuelFix(0, meters / 111194.92664455874, accuracy,
        start.add(Duration(seconds: second)), mocked: mocked);
  void add(DuelMovement detector, DuelFix f) => detector.add(f, now: f.at);

  test('ordinary running and stationary GPS wander do not invalidate', () {
    for (final speed in [0.0, 5.0, 12.0, 25.0, 28.0]) {
      final d = DuelMovement();
      for (var t = 0; t <= 120; t++) add(d, fix(t, t * speed / 3.6));
      expect(d.invalid, isFalse);
    }
    final noise = DuelMovement();
    for (var t = 0; t <= 120; t++) add(noise, fix(t, t.isEven ? 10 : -10, accuracy: 15));
    expect(noise.invalid, isFalse);
  });

  test('three sustained windows are required, with uncertainty subtracted', () {
    final d = DuelMovement();
    for (var t = 0; t < 30; t++) add(d, fix(t, t * 60 / 3.6));
    expect(d.invalid, isFalse);
    add(d, fix(30, 30 * 60 / 3.6));
    expect(d.invalid, isTrue);
    expect(DuelPolicy.invalidEvidence(d.evidence), isTrue);
    final conservative = DuelMovement();
    for (var t = 0; t <= 60; t++) add(conservative, fix(t, t * 41 / 3.6, accuracy: 20));
    expect(conservative.invalid, isFalse, reason: 'Reported speed alone is not enough after accounting for accuracy.');
  });

  test('a normal-speed window breaks sustained excessive-speed evidence', () {
    final d = DuelMovement();
    for (var t = 0; t <= 20; t++) add(d, fix(t, t * 60 / 3.6));
    for (var t = 21; t <= 30; t++) add(d, fix(t, 20 * 60 / 3.6 + (t - 20) * 5 / 3.6));
    for (var t = 31; t <= 50; t++) add(d, fix(t, 20 * 60 / 3.6 + 10 * 5 / 3.6 + (t - 30) * 60 / 3.6));
    expect(d.invalid, isFalse);
  });

  test('isolated jumps and a single bad fix do not dismiss a duel', () {
    final d = DuelMovement();
    for (var t = 0; t <= 40; t++) add(d, fix(t, t == 5 ? 1000 : 0));
    expect(d.invalid, isFalse);
  });

  test('three independent accurate jumps within 30 seconds invalidate', () {
    final d = DuelMovement();
    final meters = [0.0, 400.0, 400.0, 800.0, 800.0, 1200.0];
    for (var t = 0; t < meters.length; t++) add(d, fix(t, meters[t]));
    expect(d.invalid, isTrue);
    expect((d.evidence['jumps'] as List).length, 3);
  });

  test('jump evidence expires and poor accuracy cannot supply evidence', () {
    final expired = DuelMovement();
    for (final (t, m) in [(0, 0.0), (1, 400.0), (20, 400.0), (21, 800.0), (40, 800.0), (41, 1200.0)]) {
      add(expired, fix(t, m));
    }
    expect(expired.invalid, isFalse);
    final poor = DuelMovement();
    for (var t = 0; t <= 60; t++) add(poor, fix(t, t * 100, accuracy: 21));
    expect(poor.invalid, isFalse);
  });

  test('sparse, stale, mocked and out-of-order fixes do not trigger dismissal', () {
    final sparse = DuelMovement();
    for (var t = 0; t <= 100; t += 10) add(sparse, fix(t, t * 30));
    expect(sparse.invalid, isFalse);
    final stale = DuelMovement();
    for (var t = 0; t <= 60; t++) stale.add(fix(t, t * 30), now: start.add(Duration(seconds: t + 11)));
    expect(stale.invalid, isFalse);
    final mocked = DuelMovement();
    for (var t = 0; t <= 60; t++) add(mocked, fix(t, t * 30, mocked: true));
    expect(mocked.invalid, isFalse);
    add(mocked, fix(2, 0)); add(mocked, fix(1, 10000)); add(mocked, fix(2, 10000));
    expect(mocked.invalid, isFalse);
  });

  test('invalid evidence is latched and cannot be reset by later normal fixes', () {
    final d = DuelMovement();
    for (var t = 0; t <= 30; t++) add(d, fix(t, t * 60 / 3.6));
    final before = d.evidence;
    add(d, fix(100, 0, accuracy: 500));
    expect(d.invalid, isTrue);
    expect(d.evidence, before);
  });
}
