import 'package:cloud_firestore/cloud_firestore.dart';

/// Approved duel policy. The rules generator copies these numeric constants.
abstract final class DuelPolicy {
  static const int version = 2;
  static const int deliverySeconds = 10;
  static const int inviteSeconds = 60;
  static const int lobbySeconds = 900;
  static const int countdownSeconds = 5;
  static const int validationSeconds = 90;
  static const int presenceSeconds = 150;
  static const int cooldownSeconds = 3600;
  static const double trackingAccuracyM = 50;
  static const double trackingSpeedKmh = 28;
  static const double progressSpeedKmh = 25;
  static const double progressSlackKm = 0.2;
  static const double evidenceAccuracyM = 20;
  static const int fixAgeSeconds = 10;
  static const int windowSeconds = 10;
  static const int windowFixes = 3;
  static const int windowGapSeconds = 5;
  static const int windowCount = 3;
  static const double excessiveSpeedKmh = 40;
  static const double jumpMeters = 200;
  static const double jumpSpeedKmh = 100;
  static const int jumpMinSeconds = 1;
  static const int jumpMaxSeconds = 5;
  static const int jumpPeriodSeconds = 30;
  static const int jumpCount = 3;
  static const terminal = {'done', 'invalid', 'declined', 'cancelled', 'expired', 'busy', 'unverified'};
  static const dismissedMessage = 'Incorrect usage detected. This duel has been dismissed. Neither player will receive duel rewards.';
  static const busyMessage = 'This player is currently in an activity. Please try again later.';
  static const declinedMessage = 'This player declined your duel invitation. Please try again later.';

  static bool fresh(Map<String, dynamic>? presence, DateTime now) {
    final at = presence?['presence_at'];
    return presence?['presence'] == 'online' && at is Timestamp &&
        !at.toDate().isAfter(now) && now.difference(at.toDate()).inSeconds < presenceSeconds;
  }

  static bool expired(Map<String, dynamic> duel, DateTime now) {
    final status = duel['status'];
    final (field, seconds) = switch (status) {
      'pending' => ('created_at', duel['delivered_at'] == null ? deliverySeconds : inviteSeconds),
      'lobby' => ('accepted_at', lobbySeconds),
      'countdown' => ('countdown_at', presenceSeconds),
      'validating' => ('validating_at', validationSeconds),
      _ => ('', 0),
    };
    final at = duel[field];
    return field.isNotEmpty && at is Timestamp && !now.isBefore(at.toDate().add(Duration(seconds: seconds)));
  }

  static bool invalidEvidence(Map<String, dynamic> evidence) {
    final windows = evidence['windows'];
    final jumps = evidence['jumps'];
    bool number(Object? n) => n is num && n.isFinite;
    final fast = windows is List && windows.length == windowCount && windows.every((w) =>
      w is Map && number(w['seconds']) && w['seconds'] >= windowSeconds &&
      number(w['fixes']) && w['fixes'] >= windowFixes && number(w['gap']) &&
      w['gap'] <= windowGapSeconds && number(w['speed']) && w['speed'] > excessiveSpeedKmh);
    final jumping = jumps is List && jumps.length == jumpCount && jumps.every((j) =>
      j is Map && number(j['meters']) && j['meters'] > jumpMeters &&
      number(j['seconds']) && j['seconds'] >= jumpMinSeconds && j['seconds'] <= jumpMaxSeconds &&
      j['meters'] / j['seconds'] * 3.6 > jumpSpeedKmh) &&
      number(jumps.last['at']) && number(jumps.first['at']) &&
      jumps.last['at'] - jumps.first['at'] <= jumpPeriodSeconds;
    return fast || jumping;
  }
}
