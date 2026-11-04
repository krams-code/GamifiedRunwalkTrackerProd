import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/run_mode.dart';
import '../utils/fast_save.dart';
import '../utils/player_stats.dart';
import '../utils/rewards.dart';
import 'run_saver.dart';

/// TESTER ACCOUNTS: shortcuts for checking features that normally take days
/// of running (ranks, trials, heroes, levels, streaks, the weekly goal...).
///
/// Who is a tester is decided ONLY in the Firebase console:
///   Firestore > testers > (document id = the player's UID)
/// Players can't add themselves (the security rules refuse every write to
/// `testers`), and only a tester's own account may use these shortcuts.
/// Remove the document to turn an account back into a normal player.
abstract final class TesterMode {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Is [uid] listed in `testers`? (false on any error)
  static Future<bool> check(String uid) async {
    try {
      final s = await _db.collection('testers').doc(uid).get();
      return s.exists;
    } catch (e) {
      debugPrint('tester check: $e');
      return false;
    }
  }

  static DocumentReference<Map<String, dynamic>> _user(String uid) =>
      _db.collection('users').doc(uid);

  /// Tester accounts are left off the leaderboards.
  static Map<String, dynamic> get _flag => const {'tester': true};

  /// Clear every rank (3 stars) and every distance trial, so all run modes,
  /// rank heroes and rank items open.
  static Future<void> unlockAllModes(String uid) {
    final records = <String, dynamic>{
      for (final m in [...kStageModes, ...kTrialModes])
        m.id: {
          'stars': m.isTrial ? 1 : 3,
          'best_secs': ((m.clockSeconds ?? 600) * 0.5).round(),
          'clears': 1,
        },
    };
    return _user(uid).update({..._flag, 'stage_records': records});
  }

  /// Lock every rank and trial again (to test the unlock flow from zero).
  static Future<void> lockAllModes(String uid) =>
      _user(uid).update({..._flag, 'stage_records': <String, dynamic>{}});

  static Future<void> addCoins(String uid, int coins) =>
      _user(uid).update({..._flag, 'coins': FieldValue.increment(coins)});

  /// Add exactly enough XP to reach the next [levels] levels.
  static Future<void> addLevels(String uid, int currentXp, int levels) {
    var xp = currentXp;
    for (var i = 0; i < levels; i++) {
      final lv = LevelProgress.fromXp(xp);
      xp += lv.xpNeeded - lv.xpIntoLevel;
    }
    return _user(uid)
        .update({..._flag, 'xp': FieldValue.increment(xp - currentXp)});
  }

  /// Raise lifetime km (items / heroes with a "Run N total km" rule).
  static Future<void> addTotalKm(String uid, double km) =>
      _user(uid).update({..._flag, 'total_km': FieldValue.increment(km)});

  /// Make every "wait" open again: streak reward (12 h), weekly goal reward,
  /// today's daily quests, the daily coin cap and the weekly check-in.
  static Future<void> resetTimers(String uid) =>
      _user(uid).update(_timersCleared());

  static Map<String, dynamic> _timersCleared() => {
        ..._flag,
        'streak_claim_at': FieldValue.delete(),
        'streak_claims': <String>[],
        'weekly_goal_claimed': FieldValue.delete(),
        'weekly_claim_week': FieldValue.delete(),
        'daily_quests_claimed': <String, dynamic>{},
        'daily_progress_km': 0.0,
        'coins_today': 0,
        // a check-in 8 days ago: the weekly check-in opens right away
        'last_checkin_at': Timestamp.fromDate(
            DateTime.now().subtract(const Duration(days: 8))),
      };

  /// Back to a brand-new player's progress: no ranks, level 1, 0 km, 100
  /// coins, every timer open. Bought items, the hero and run history stay.
  static Future<void> resetProgress(String uid) => _user(uid).update({
        ..._timersCleared(),
        'stage_records': <String, dynamic>{},
        'xp': 0,
        'total_km': 0.0,
        'coins': 100,
        'loot_chests': 0,
      });

  /// Save a finished run of [km] in [minutes] that ended just now, through
  /// the NORMAL run save (XP, coins, daily quests, weekly goal, badges).
  static Future<RunSaveResult> addTestRun(String uid,
      {double km = 3.0, int minutes = 20}) async {
    // (no waiting: the flag is saved in the background)
    _user(uid).update(_flag).catchError((Object _) {});
    // runs may not overlap: if the last run ended less than [minutes] ago,
    // this test run starts right after it
    final snap = await localFirst(_user(uid));
    final lastEnd = (snap.data()?['last_run_end'] as Timestamp?)?.toDate();
    var start = DateTime.now().subtract(Duration(minutes: minutes));
    if (lastEnd != null && start.isBefore(lastEnd)) {
      start = lastEnd.add(const Duration(seconds: 5));
    }
    final end = start.add(Duration(minutes: minutes));
    final secs = minutes * 60;
    final mode = kEndless; // free run: no rank is cleared by a test run
    final xp = RunRewards.xp(km: km, activeSeconds: secs, mult: mode.rewardMult);
    final coins = RunRewards.coins(km: km, mult: mode.rewardMult);
    final kmh = km / (secs / 3600);
    final p = RunPayload(
      id: '${start.millisecondsSinceEpoch}',
      uid: uid,
      modeId: mode.id,
      outcome: null,
      good: false,
      rewardMult: mode.rewardMult,
      fields: {
        'type': kmh >= 10 ? 'run' : (kmh >= 6 ? 'jog' : 'walk'),
        'userPick': 'run',
        'startTime': start.millisecondsSinceEpoch,
        'endTime': end.millisecondsSinceEpoch,
        'distanceKm': km,
        'durationSeconds': secs,
        'activeSeconds': secs,
        'avgSpeedKmh': double.parse(kmh.toStringAsFixed(2)),
        'maxSpeedKmh': double.parse((kmh * 1.2).toStringAsFixed(2)),
        'xpEarned': xp,
        'coinsEarned': coins,
        'routePoints': const <Map<String, double>>[],
        'test_run': true,
      },
      challenges: const [],
      ghost: null,
      xp: xp,
      coins: coins,
      bonusCoins: 0,
      lootChests: 0,
      elapsedSeconds: secs,
    );
    return RunSaver.save(p).timeout(RunSaver.timeout);
  }

  /// One short run on each of the last [days] days (before today), so the
  /// day streak and streak rewards can be tested. History only: these runs
  /// give no XP or coins.
  static Future<void> addStreakDays(String uid, int days) async {
    final acts = _user(uid).collection('activities');
    final now = DateTime.now();
    final batch = _db.batch();
    batch.update(_user(uid), _flag);
    final stamp = now.millisecondsSinceEpoch % 100000;
    for (var i = 1; i <= days; i++) {
      final d = now.subtract(Duration(days: i));
      final start = DateTime(d.year, d.month, d.day, 7, 0);
      final end = start.add(const Duration(minutes: 15));
      // own id per tap, so pressing the button twice never clashes
      batch.set(acts.doc('${start.millisecondsSinceEpoch}_t$stamp'), {
        'type': 'jog',
        'userPick': 'run',
        'startTime': Timestamp.fromDate(start),
        'endTime': Timestamp.fromDate(end),
        'distanceKm': 2.0,
        'durationSeconds': 900,
        'activeSeconds': 900,
        'avgSpeedKmh': 8.0,
        'maxSpeedKmh': 9.5,
        'xpEarned': 0,
        'coinsEarned': 0,
        'routePoints': const <Map<String, double>>[],
        'mode': kEndless.id,
        'no_rewards': true,
        'test_run': true,
      });
    }
    await batch.commit();
  }
}
