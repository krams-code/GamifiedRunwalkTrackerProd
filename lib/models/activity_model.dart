import 'package:cloud_firestore/cloud_firestore.dart';

enum ActivityType { walk, jog, run }

extension ActivityTypeExt on ActivityType {
  String get label {
    switch (this) {
      case ActivityType.walk: return 'Walk';
      case ActivityType.jog:  return 'Jog';
      case ActivityType.run:  return 'Run';
    }
  }

  String get emoji {
    switch (this) {
      case ActivityType.walk: return '🚶';
      case ActivityType.jog:  return '🏃';
      case ActivityType.run:  return '⚡';
    }
  }

  // Speed thresholds in km/h (average MOVING speed of the whole run):
  //   walk  < 6.5 km/h   (pace slower than about 9:15 per km)
  //   jog   6.5 - 9.7    (about 9:15 - 6:10 per km)
  //   run   >= 9.7       (6 mph and faster, the usual jog / run line)
  static const double jogFromKmh = 6.5;
  static const double runFromKmh = 9.7;

  static ActivityType fromSpeed(double kmh) {
    if (kmh >= runFromKmh) return ActivityType.run;
    if (kmh >= jogFromKmh) return ActivityType.jog;
    return ActivityType.walk;
  }
}

class ActivitySession {
  final String id;
  final ActivityType type;         // final classified type
  final ActivityType userPick;     // what user selected before starting
  final DateTime startTime;
  final DateTime endTime;
  final double distanceKm;
  final int durationSeconds;
  final double avgSpeedKmh;
  final double maxSpeedKmh;
  final int xpEarned;
  final int coinsEarned;
  final List<Map<String, double>> routePoints; // [{lat, lng}]

  const ActivitySession({
    required this.id,
    required this.type,
    required this.userPick,
    required this.startTime,
    required this.endTime,
    required this.distanceKm,
    required this.durationSeconds,
    required this.avgSpeedKmh,
    required this.maxSpeedKmh,
    required this.xpEarned,
    required this.coinsEarned,
    this.routePoints = const [],
  });

  String get formattedDuration {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    final s = durationSeconds % 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m ${s}s';
  }

  String get formattedPace {
    if (distanceKm <= 0) return '--:--';
    final secsPerKm = durationSeconds / distanceKm;
    final m = secsPerKm ~/ 60;
    final s = (secsPerKm % 60).toInt();
    return "$m'${s.toString().padLeft(2, '0')}\"";
  }

  Map<String, dynamic> toFirestore() => {
    'type':            type.name,
    'userPick':        userPick.name,
    'startTime':       Timestamp.fromDate(startTime),
    'endTime':         Timestamp.fromDate(endTime),
    'distanceKm':      distanceKm,
    'durationSeconds': durationSeconds,
    'avgSpeedKmh':     avgSpeedKmh,
    'maxSpeedKmh':     maxSpeedKmh,
    'xpEarned':        xpEarned,
    'coinsEarned':     coinsEarned,
    'routePoints':     routePoints,
  };

  factory ActivitySession.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return ActivitySession(
      id:              doc.id,
      // the saved average speed decides (older app versions labelled most
      // runs "walk" by mistake); the saved type only when there is no speed
      type:            ((d['avgSpeedKmh'] as num?)?.toDouble() ?? 0) > 0.5
                         ? ActivityTypeExt.fromSpeed(
                             (d['avgSpeedKmh'] as num).toDouble())
                         : ActivityType.values.firstWhere(
                             (e) => e.name == (d['type'] ?? 'walk'),
                             orElse: () => ActivityType.walk),
      userPick:        ActivityType.values.firstWhere(
                         (e) => e.name == (d['userPick'] ?? 'run'),
                         orElse: () => ActivityType.run),
      startTime:       (d['startTime'] as Timestamp).toDate(),
      endTime:         (d['endTime'] as Timestamp).toDate(),
      distanceKm:      (d['distanceKm'] as num).toDouble(),
      durationSeconds: (d['durationSeconds'] as num).toInt(),
      avgSpeedKmh:     (d['avgSpeedKmh'] as num).toDouble(),
      maxSpeedKmh:     (d['maxSpeedKmh'] as num).toDouble(),
      xpEarned:        (d['xpEarned'] as num).toInt(),
      coinsEarned:     (d['coinsEarned'] as num).toInt(),
      routePoints:     (d['routePoints'] as List<dynamic>? ?? [])
                         .map((p) => Map<String, double>.from(
                               (p as Map).map((k, v) =>
                                 MapEntry(k.toString(), (v as num).toDouble()))))
                         .toList(),
    );
  }
}