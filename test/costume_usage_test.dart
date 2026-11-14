import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/models/hero_progress.dart';
import 'package:hakbanghero/models/hero_roster.dart';
import 'package:hakbanghero/services/costume_usage.dart';

// Transactions are exercised without connecting to a Firebase project.
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
  String get id => path.split('/').last;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) => _Collection('${this.path}/$path');
}

// ignore: subtype_of_sealed_class
class _Snapshot<T extends Object?> extends Fake implements DocumentSnapshot<T> {
  _Snapshot(this.value);
  final T? value;
  @override
  T? data() => value;
}

class _Transaction extends Fake implements Transaction {
  _Transaction(this.db);
  final _Database db;
  final writes = <String, Map<String, dynamic>>{};
  bool writing = false;
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(DocumentReference<T> ref) async {
    expect(writing, isFalse, reason: 'Firestore requires all reads before writes.');
    return _Snapshot<T>(db.documents[ref.path] as T?);
  }
  @override
  Transaction update(DocumentReference ref, Map<String, dynamic> data) {
    writing = true;
    writes[ref.path] = data;
    return this;
  }
  @override
  Transaction set<T>(DocumentReference<T> ref, T data, [SetOptions? options]) {
    expect(options?.merge, isTrue);
    writing = true;
    writes[ref.path] = Map<String, dynamic>.from(data as Map);
    return this;
  }
}

class _Database extends Fake implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{
    'users/player': {
      'hero_id': 'sprout', 'owned_heroes': ['sprout', 'frog', 'penguin', 'slime'],
      'coins': 1000, 'xp': 0, 'hero_outfit': {'head': 'cap_red'}, 'username': 'Runner',
    },
  };
  Map<String, Map<String, dynamic>> committed = {};
  Object? failure;
  void Function()? beforeRetry;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) => _Collection(path);
  @override
  Future<T> runTransaction<T>(TransactionHandler<T> handler, {
    Duration timeout = const Duration(seconds: 30), int maxAttempts = 5,
  }) async {
    final retry = beforeRetry;
    beforeRetry = null;
    if (retry != null) {
      await handler(_Transaction(this));
      retry();
    }
    final transaction = _Transaction(this);
    final result = await handler(transaction);
    if (failure != null) throw failure!;
    committed = transaction.writes;
    for (final entry in committed.entries) {
      documents[entry.key] = {...?documents[entry.key],
        // Existing arrayUnion is inspected separately; this fake does not
        // emulate Firestore transforms or evaluate deployed security rules.
        for (final field in entry.value.entries)
          if (field.value is! FieldValue) field.key: field.value,
      };
    }
    return result;
  }
}

void main() {
  final user = _Document('users/player');
  const path = 'users/player/private/wardrobe';
  List<String> order(_Database db) => List<String>.from(db.documents[path]![CostumeUsage.field]);
  Future<bool> equip(_Database db, String id) => CostumeUsage.equip(user, heroById(id)!, firestore: db);

  test('legacy accounts show the equipped hero first, then stable roster order', () {
    final available = kHeroes.take(4).toList();
    expect(CostumeUsage.ordered(available, 'penguin', null).map((h) => h.id),
        ['penguin', 'sprout', 'frog', 'slime']);
    expect(CostumeUsage.ordered([], 'sprout', null), isEmpty);
  });

  test('usage is distinct and filters unknown IDs without changing eligibility', () {
    final progress = HeroProgress.fromData({'owned_heroes': ['bear']});
    final available = kHeroes.where((h) => isHeroUnlocked(h, progress)).toList();
    final ordered = CostumeUsage.ordered(available, 'frog', ['penguin', 'penguin', 'unknown', 7, 'dragon']);
    expect(ordered.take(3).map((h) => h.id), ['penguin', 'frog', 'sprout']);
    expect(ordered.map((h) => h.id).toSet(), available.map((h) => h.id).toSet());
  });

  test('successful equips preserve profile data and build the last three distinct choices', () async {
    final db = _Database();
    for (final id in ['frog', 'penguin', 'slime', 'frog']) {
      expect(await equip(db, id), isTrue);
    }
    expect(order(db), ['frog', 'slime', 'penguin', 'sprout']);
    final profile = db.documents['users/player']!;
    expect(profile['hero_id'], 'frog');
    expect(profile['owned_heroes'], ['sprout', 'frog', 'penguin', 'slime']);
    expect(profile['coins'], 1000);
    expect(profile['hero_outfit'], {'head': 'cap_red'});
    expect(profile['username'], 'Runner');
    expect(db.committed['users/player']!['owned_heroes'], isA<FieldValue>());
    expect(db.documents[path]!.keys, [CostumeUsage.field], reason: 'No invented usage timestamps.');
  });

  test('already equipped costumes do not write or create history', () async {
    final db = _Database();
    expect(await equip(db, 'sprout'), isFalse);
    expect(db.committed, isEmpty);
    expect(db.documents.containsKey(path), isFalse);
    await equip(db, 'frog');
    final before = order(db);
    expect(await equip(db, 'frog'), isFalse);
    expect(order(db), before);
    expect(db.committed, isEmpty);
  });

  test('history survives another reader and newly owned costumes stay behind used ones', () async {
    final db = _Database();
    await equip(db, 'frog');
    await equip(db, 'penguin');
    db.documents['users/player']!['owned_heroes'] = ['sprout', 'frog', 'penguin', 'slime', 'bear'];
    final profile = Map<String, dynamic>.from(db.documents['users/player']!);
    final persisted = Map<String, dynamic>.from(db.documents[path]!);
    final available = kHeroes.where((h) => isHeroUnlocked(h, HeroProgress.fromData(profile))).toList();
    expect(CostumeUsage.ordered(available, profile['hero_id'] as String, persisted[CostumeUsage.field])
        .take(3).map((h) => h.id), ['penguin', 'frog', 'sprout']);
  });

  test('failed equip rolls back both documents and can be retried', () async {
    final db = _Database();
    await equip(db, 'frog');
    db.failure = FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
    await expectLater(equip(db, 'penguin'), throwsA(isA<FirebaseException>()));
    expect(db.documents['users/player']!['hero_id'], 'frog');
    expect(order(db), ['frog', 'sprout']);
    db.failure = null;
    await equip(db, 'penguin');
    expect(order(db), ['penguin', 'frog', 'sprout']);
  });

  test('transaction retry includes another device equip without losing history', () async {
    final db = _Database();
    db.beforeRetry = () {
      db.documents['users/player']!['hero_id'] = 'slime';
      db.documents[path] = {CostumeUsage.field: ['slime', 'penguin', 'sprout']};
    };
    await equip(db, 'frog');
    expect(order(db), ['frog', 'slime', 'penguin', 'sprout']);
  });

  test('shop look writes update recency only when the equipped hero changes', () async {
    final db = _Database();
    await equip(db, 'frog');
    expect(await CostumeUsage.saveLook(user, (_) => {
      'hero_id': 'frog', 'hero_outfit': {'head': 'beanie_blue'},
      'owned_heroes': ['sprout', 'frog', 'penguin', 'slime', 'bear'],
    }, firestore: db), isFalse);
    expect(order(db), ['frog', 'sprout']);
    expect(db.committed.containsKey(path), isFalse);
    await CostumeUsage.saveLook(user, (_) => {'hero_id': 'bear', 'coins': 700}, firestore: db);
    expect(order(db), ['bear', 'frog', 'sprout']);
    expect(db.documents['users/player']!['coins'], 700);
  });

  test('locked costumes and missing profiles cannot produce a usage entry', () async {
    final db = _Database();
    await expectLater(equip(db, 'dragon'), throwsStateError);
    expect(db.committed, isEmpty);
    db.documents.remove('users/player');
    await expectLater(equip(db, 'frog'), throwsStateError);
    expect(db.documents.containsKey(path), isFalse);
  });

  test('a first hero choice records only the actual choice', () async {
    final db = _Database();
    db.documents['users/player']!.remove('hero_id');
    await equip(db, 'penguin');
    expect(order(db), ['penguin']);
  });
}
