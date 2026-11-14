import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// Existing FlutterFire test support; no additional dependencies are needed.
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/services/run_saver.dart';
import 'package:hakbanghero/utils/weekly.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Auth extends FirebaseAuthPlatform {
  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => this;
  @override
  FirebaseAuthPlatform setInitialValues({PigeonUserDetails? currentUser, String? languageCode}) => this;
  @override
  UserPlatform? get currentUser => null;
}

class _Storage extends InMemorySharedPreferencesStore {
  _Storage() : super.empty();
  bool fail = true;
  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      fail ? Future.value(false) : super.setValue(valueType, key, value);
}

RunPayload payload(String id) {
  final start = DateTime.now().subtract(const Duration(minutes: 20));
  return RunPayload(
    id: id, uid: 'runner', modeId: 'endless', outcome: null, good: false,
    rewardMult: 0.8, xp: 239, coins: 16, bonusCoins: 0, lootChests: 0,
    elapsedSeconds: 1200, challenges: const [], ghost: null,
    fields: {
      'startTime': start.millisecondsSinceEpoch,
      'endTime': start.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
      'distanceKm': 2.0, 'durationSeconds': 1200,
      'xpEarned': 239, 'coinsEarned': 16,
    },
  );
}

// Test doubles exercise transactions without a device or Firebase backend.
// ignore: subtype_of_sealed_class
class _Collection extends Fake implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.path);
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) => _Document('$path/$id');
}

// ignore: subtype_of_sealed_class
class _Document extends Fake implements DocumentReference<Map<String, dynamic>> {
  _Document(this.path);
  @override
  final String path;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) => _Collection('${this.path}/$path');
}

// ignore: subtype_of_sealed_class
class _Snapshot<T extends Object?> extends Fake implements DocumentSnapshot<T> {
  _Snapshot(this.value);
  final T? value;
  @override
  bool get exists => value != null;
  @override
  T? data() => value;
}

class _Transaction extends Fake implements Transaction {
  _Transaction(this.database);
  final _Database database;
  final writes = <String, Map<String, dynamic>>{};
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(DocumentReference<T> ref) async =>
      _Snapshot<T>(database.documents[ref.path] as T?);
  @override
  Transaction set<T>(DocumentReference<T> ref, T data, [SetOptions? options]) {
    writes[ref.path] = Map<String, dynamic>.from(data as Map);
    return this;
  }
  @override
  Transaction update(DocumentReference ref, Map<String, dynamic> data) {
    writes[ref.path] = data;
    return this;
  }
}

class _Database extends Fake implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{
    'users/runner': {'xp': 100, 'coins': 100, 'total_km': 0.0, 'total_sessions': 0},
  };
  Map<String, Map<String, dynamic>> committed = {};
  Object? failure;
  bool retry = false;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) => _Collection(path);
  @override
  Future<T> runTransaction<T>(TransactionHandler<T> handler, {
    Duration timeout = const Duration(seconds: 30), int maxAttempts = 5,
  }) async {
    if (retry) await handler(_Transaction(this));
    final transaction = _Transaction(this);
    final result = await handler(transaction);
    if (failure != null) throw failure!;
    committed = transaction.writes;
    for (final entry in committed.entries) {
      documents[entry.key] = {...?documents[entry.key], ...entry.value};
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  FirebaseAuthPlatform.instance = _Auth();
  setUpAll(() async => Firebase.initializeApp());
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('run history, totals and current leaderboard fields commit together', () async {
    final db = _Database();
    final p = payload('valid');
    final result = await RunSaver.save(p, firestore: db);
    final activity = db.committed['users/runner/activities/valid']!;
    final user = db.committed['users/runner']!;
    expect(activity['xpEarned'], 239);
    expect(activity['coinsEarned'], 16);
    expect(activity['awardedXp'], result.awardedXp);
    expect(activity['awardedCoins'], result.awardedCoins);
    expect(user['xp'], FieldValue.increment(239));
    expect(user['coins'], FieldValue.increment(result.awardedCoins));
    expect(user['total_km'], FieldValue.increment(2.0));
    expect(user['total_sessions'], FieldValue.increment(1));
    expect(user['week_key'], Weekly.key(DateTime.now()));
    expect(user['week_km'], 2.0);
    expect(user['month_km'], 2.0);
    expect(user['last_run_id'], 'valid');
    expect(result.awardedXp, 239);
  });

  test('same run cannot award twice, including a retried transaction handler', () async {
    final db = _Database()..retry = true;
    final p = payload('duplicate');
    await RunSaver.save(p, firestore: db);
    final again = await RunSaver.save(p, firestore: db);
    expect(again.duplicate, isTrue);
    expect(again.awardedXp, 0);
    expect(again.awardedCoins, 0);
    expect(db.committed, isEmpty);
  });

  test('stage records and bonuses commit with the activity and totals', () async {
    final db = _Database();
    final base = payload('stage');
    final p = RunPayload.fromJson({
      ...base.toJson(), 'modeId': 'stage_novice',
      'outcome': 'STAGE CLEARED!', 'good': true, 'rewardMult': 1.0,
      'xp': 299, 'coins': 20,
      'fields': {...base.fields, 'xpEarned': 299, 'coinsEarned': 20},
    });
    final result = await RunSaver.save(p, firestore: db);
    final user = db.committed['users/runner']!;
    expect(user['stage_records']['stage_novice']['clears'], 1);
    expect(user['stage_records']['stage_novice']['stars'], greaterThan(0));
    expect(result.firstClear, isTrue);
    expect(result.bonusCoins, greaterThan(0));
    expect(result.awardedCoins, greaterThan(20));
    expect(db.committed['users/runner/activities/stage']!['stage_result'], 'STAGE CLEARED!');
  });

  test('old-period runs do not add distance to current leaderboard periods', () async {
    final db = _Database();
    final base = payload('old');
    final start = DateTime.now().subtract(const Duration(days: 70));
    final p = RunPayload.fromJson({
      ...base.toJson(),
      'fields': {...base.fields,
        'startTime': start.millisecondsSinceEpoch,
        'endTime': start.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
      },
    });
    final result = await RunSaver.save(p, firestore: db);
    final user = db.committed['users/runner']!;
    expect(user.containsKey('week_km'), isFalse);
    expect(user.containsKey('month_km'), isFalse);
    expect(result.awardedXp, 239);
    expect(user['total_km'], FieldValue.increment(2.0));
  });

  test('previous history-only fallbacks are reported instead of silently discarded', () async {
    final db = _Database();
    db.documents['users/runner/activities/history'] = {'no_rewards': true};
    await expectLater(RunSaver.saveQueued(payload('history'), firestore: db), throwsStateError);
    expect(db.committed, isEmpty);
  });

  test('a rejected queued save propagates failure without history-only fallback', () async {
    final db = _Database()
      ..failure = FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
    final p = payload('rejected');
    await RunOutbox.enqueue(p);
    await expectLater(RunSaver.saveQueued(p, firestore: db), throwsA(isA<FirebaseException>()));
    expect(db.committed, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getStringList('run_outbox_v1')!.single) as Map;
    expect(saved['xp'], 239);
    expect(saved['coins'], 16);
    expect(await RunOutbox.pendingCount('runner'), 1);
  });

  test('concurrent queue writes retain distinct runs and deduplicate the same run', () async {
    await Future.wait([
      RunOutbox.enqueue(payload('a')),
      RunOutbox.enqueue(payload('b')),
      RunOutbox.enqueue(payload('a')),
    ]);
    expect(await RunOutbox.pendingCount('runner'), 2);
    await Future.wait([
      RunOutbox.remove('runner', 'a'),
      RunOutbox.enqueue(payload('c')),
    ]);
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('run_outbox_v1')!
        .map((raw) => (jsonDecode(raw) as Map)['id']).toSet();
    expect(ids, {'b', 'c'});
  });

  test('coin cap changes the credited amount without discarding XP', () async {
    final db = _Database();
    db.documents['users/runner']!.addAll({
      'coins_today_day': RunSaver.coinDay(), 'coins_today': 11999,
    });
    final result = await RunSaver.save(payload('capped'), firestore: db);
    expect(result.awardedCoins, 1);
    expect(db.committed['users/runner/activities/capped']!['awardedCoins'], 1);
    expect(result.awardedXp, 239);
  });

  test('failed local writes report failure and do not masquerade as retained runs', () async {
    final storage = _Storage();
    SharedPreferencesStorePlatform.instance = storage;
    await expectLater(RunOutbox.enqueue(payload('storage')), throwsStateError);
    expect(await RunOutbox.pendingCount('runner'), 0);
    storage.fail = false;
    await RunOutbox.enqueue(payload('storage'));
    expect(await RunOutbox.pendingCount('runner'), 1);
  });

  test('an overlapping run stays history-only under the existing eligibility rule', () async {
    final db = _Database();
    db.documents['users/runner']!['last_run_end'] = Timestamp.now();
    final result = await RunSaver.save(payload('overlap'), firestore: db);
    expect(result.late, isTrue);
    expect(db.committed.containsKey('users/runner'), isFalse);
    expect(db.committed['users/runner/activities/overlap']!['xpEarned'], 0);
    expect(db.committed['users/runner/activities/overlap']!['awardedCoins'], 0);
  });
}
