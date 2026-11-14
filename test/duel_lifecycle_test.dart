import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/models/duel_policy.dart';
import 'package:hakbanghero/services/presence.dart';

void main() {
  final now = DateTime.utc(2026, 11, 14);
  test('missing, stale, idle, offline and future presence are unavailable', () {
    for (final data in [null, <String, dynamic>{'presence': 'online'},
      {'presence': 'online', 'presence_at': Timestamp.fromDate(now.subtract(const Duration(seconds: 150)))},
      {'presence': 'online', 'presence_at': Timestamp.fromDate(now.add(const Duration(seconds: 1)))},
      {'presence': 'idle', 'presence_at': Timestamp.fromDate(now)},
      {'presence': 'offline', 'presence_at': Timestamp.fromDate(now)},
    ]) {
      expect(DuelPolicy.fresh(data, now), isFalse);
    }
    expect(DuelPolicy.fresh({'presence': 'online', 'presence_at': Timestamp.fromDate(now)}, now), isTrue);
    expect(Presence.statusOf({'presence': 'online'}), PresenceStatus.offline);
  });
  test('undelivered invitations expire after ten seconds, acknowledged ones after sixty', () {
    Map<String, dynamic> pending(int age) => {'status': 'pending',
      'created_at': Timestamp.fromDate(now.subtract(Duration(seconds: age)))};
    expect(DuelPolicy.expired(pending(9), now), isFalse);
    expect(DuelPolicy.expired(pending(10), now), isTrue);
    expect(DuelPolicy.expired(pending(59)..['delivered_at'] = Timestamp.fromDate(now), now), isFalse);
    expect(DuelPolicy.expired(pending(60)..['delivered_at'] = Timestamp.fromDate(now), now), isTrue);
  });
  test('lobbies and validation have bounded lifetimes and terminal states remain terminal', () {
    expect(DuelPolicy.expired({'status': 'lobby', 'accepted_at': Timestamp.fromDate(now.subtract(const Duration(minutes: 15)))}, now), isTrue);
    expect(DuelPolicy.expired({'status': 'validating', 'validating_at': Timestamp.fromDate(now.subtract(const Duration(seconds: 90)))}, now), isTrue);
    for (final status in DuelPolicy.terminal) expect(DuelPolicy.expired({'status': status}, now), isFalse);
    expect(DuelPolicy.cooldownSeconds, 3600);
  });
  test('a movement flag alone cannot supply approved invalidation evidence', () {
    expect(DuelPolicy.invalidEvidence({'invalid': true, 'windows': [], 'jumps': []}), isFalse);
    expect(DuelPolicy.invalidEvidence({'invalid': true, 'windows': [{'speed': 100}]}), isFalse);
  });
}
