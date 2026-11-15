import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/services/google_auth.dart';

class _User extends Fake implements User {
  @override
  final String uid;
  _User(this.uid);
  @override
  String? get email => 'test@example.invalid';
}

// ignore: subtype_of_sealed_class
class _Collection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.path);
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      _Document('$path/$id');
}

// ignore: subtype_of_sealed_class
class _Document extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _Document(this.path);
  @override
  final String path;
  @override
  CollectionReference<Map<String, dynamic>> collection(String name) =>
      _Collection('$path/$name');
}

// ignore: subtype_of_sealed_class
class _Snapshot<T extends Object?> extends Fake implements DocumentSnapshot<T> {
  final T? value;
  _Snapshot(this.value);
  @override
  T? data() => value;
  @override
  bool get exists => value != null;
}

class _Transaction extends Fake implements Transaction {
  final _Database db;
  final writes = <String, Map<String, dynamic>>{};
  _Transaction(this.db);
  @override
  Future<DocumentSnapshot<T>> get<T extends Object?>(
    DocumentReference<T> ref,
  ) async {
    expect(
      writes,
      isEmpty,
      reason: 'Every transaction read must precede writes.',
    );
    return _Snapshot<T>(db.documents[ref.path] as T?);
  }

  @override
  Transaction set<T>(DocumentReference<T> ref, T data, [SetOptions? options]) {
    writes[ref.path] = Map<String, dynamic>.from(data as Map);
    return this;
  }
}

class _Database extends Fake implements FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{};
  Object? failure;
  void Function()? beforeRetry;
  int transactions = 0;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(path);
  @override
  Future<T> runTransaction<T>(
    TransactionHandler<T> handler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    transactions++;
    if (failure != null) throw failure!;
    if (beforeRetry != null) {
      await handler(_Transaction(this));
      beforeRetry!();
      beforeRetry = null;
    }
    final transaction = _Transaction(this);
    final result = await handler(transaction);
    for (final entry in transaction.writes.entries) {
      documents[entry.key] = {...?documents[entry.key], ...entry.value};
    }
    return result;
  }
}

void main() {
  test(
    'profile, username and consent are created atomically for manual signup',
    () async {
      final db = _Database();
      await GoogleAuth.ensureUserDoc(
        _User('manual'),
        'Runner',
        gender: 'female',
        termsAccepted: true,
        privacyAcknowledged: true,
        firestore: db,
      );
      expect(
        db.documents.keys,
        containsAll([
          'users/manual',
          'usernames/runner',
          'users/manual/private/body',
          'users/manual/private/consent',
        ]),
      );
      expect(db.documents['users/manual']!['gender'], 'female');
      expect(db.documents['users/manual']!['character_created'], false);
      expect(db.documents['users/manual']!['legal_consent_required'], true);
    },
  );

  test(
    'restoration creates an incomplete profile requiring consent and BMI',
    () async {
      final db = _Database();
      await GoogleAuth.ensureUserDoc(
        _User('restore'),
        'Google Hero',
        firestore: db,
      );
      expect(db.documents['users/restore']!['character_created'], false);
      expect(db.documents['users/restore']!['legal_consent_required'], true);
      expect(db.documents.containsKey('users/restore/private/consent'), false);
    },
  );

  test(
    'a transaction retry cannot overwrite a profile completed on another device',
    () async {
      final db = _Database();
      const existing = {
        'username': 'Existing',
        'coins': 900,
        'xp': 500,
        'character_created': true,
        'hero_id': 'frog',
      };
      db.beforeRetry = () => db.documents['users/race'] = {...existing};
      await GoogleAuth.ensureUserDoc(_User('race'), 'New Name', firestore: db);
      expect(db.documents['users/race'], existing);
      expect(db.documents.length, 1);
    },
  );

  test(
    'concurrent bootstrap requests share work and preserve the first signup inputs',
    () async {
      final db = _Database();
      final user = _User('concurrent');
      final a = GoogleAuth.ensureUserDoc(
        user,
        'Chosen Name',
        gender: 'female',
        firestore: db,
      );
      final b = GoogleAuth.ensureUserDoc(user, 'Hero', firestore: db);
      await Future.wait([a, b]);
      expect(db.transactions, 1);
      expect(db.documents['users/concurrent']!['username'], 'Chosen Name');
      expect(db.documents['users/concurrent']!['gender'], 'female');
    },
  );

  test(
    'database errors are not retried as name collisions; failed bootstrap can retry',
    () async {
      final db = _Database()
        ..failure = FirebaseException(
          plugin: 'cloud_firestore',
          code: 'permission-denied',
        );
      final user = _User('failure');
      await expectLater(
        GoogleAuth.ensureUserDoc(user, 'Name', firestore: db),
        throwsA(isA<FirebaseException>()),
      );
      expect(db.transactions, 1);
      expect(db.documents, isEmpty);
      db.failure = null;
      await GoogleAuth.ensureUserDoc(user, 'Name', firestore: db);
      expect(db.documents['users/failure']!['username'], 'Name');
    },
  );
}
