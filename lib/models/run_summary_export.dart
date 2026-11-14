import 'package:cloud_firestore/cloud_firestore.dart';
import 'activity_model.dart';
import 'run_mode.dart';

/// Only fields allowed in the public image. No account or route data is kept.
class RunSummaryExport {
  final ActivityType type;
  final DateTime endedAt;
  final int durationSeconds;
  final double distanceKm;
  final double averageSpeed;
  final double maximumSpeed;
  final int xp;
  final int coins;
  final String mode;
  final String result;

  const RunSummaryExport({required this.type, required this.endedAt,
    required this.durationSeconds, required this.distanceKm,
    required this.averageSpeed, required this.maximumSpeed,
    required this.xp, required this.coins, required this.mode, required this.result});

  factory RunSummaryExport.fromRecord(Map<String, dynamic> record) {
    double number(String key) {
      final value = record[key];
      if (value is! num || !value.isFinite || value < 0) {
        throw StateError('This saved run has invalid statistics.');
      }
      return value.toDouble();
    }
    int integer(String key) {
      final value = record[key];
      if (value is! int || value < 0) {
        throw StateError('Confirmed reward information is unavailable for this run.');
      }
      return value;
    }
    final end = record['endTime'];
    if (end is! Timestamp) throw StateError('The run has not been confirmed yet.');
    final seconds = integer('durationSeconds');
    final speed = number('avgSpeedKmh');
    final type = ActivityType.values.firstWhere((t) => t.name == record['type'],
        orElse: () => ActivityTypeExt.fromSpeed(speed));
    final mode = RunMode.byId(record['mode'] is String ? record['mode'] as String : '');
    const results = ['STAGE CLEARED!', 'TIME UP', 'ENDED EARLY', 'INTERVALS DONE!'];
    return RunSummaryExport(
      type: type, endedAt: end.toDate(), durationSeconds: seconds,
      distanceKm: number('distanceKm'), averageSpeed: speed,
      maximumSpeed: number('maxSpeedKmh'), xp: integer('awardedXp'),
      coins: integer('awardedCoins'), mode: mode?.name ?? 'Run session',
      result: record['late'] == true ? 'HISTORY ONLY' :
          results.contains(record['stage_result']) ? record['stage_result'] as String : 'SESSION COMPLETE',
    );
  }

  String get date => '${endedAt.year}-${endedAt.month.toString().padLeft(2, '0')}-${endedAt.day.toString().padLeft(2, '0')}';
  String get fileName => 'hakbanghero_$date.png';
  String get duration {
    final h = durationSeconds ~/ 3600;
    final m = (durationSeconds % 3600) ~/ 60;
    final s = durationSeconds % 60;
    return '${h > 0 ? '$h:' : ''}${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  String get pace {
    if (distanceKm <= 0) return '--:--';
    final seconds = durationSeconds / distanceKm;
    return "${seconds ~/ 60}'${(seconds % 60).toInt().toString().padLeft(2, '0')}\"";
  }
}
