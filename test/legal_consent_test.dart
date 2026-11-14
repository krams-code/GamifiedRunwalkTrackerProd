import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/models/legal_documents.dart';
import 'package:hakbanghero/screens/auth/signup_screen.dart';
import 'package:hakbanghero/screens/auth/legal_document_screen.dart';
import 'package:hakbanghero/services/legal_consent.dart';
import 'package:hakbanghero/widgets/legal_consent_controls.dart';

class _Metadata extends Fake implements SnapshotMetadata {
  _Metadata(this.pending);
  final bool pending;
  @override
  bool get hasPendingWrites => pending;
}

// Test adapters keep persistence checks separate from live Firebase.
// ignore: subtype_of_sealed_class
class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.database);
  final _Database database;
  @override
  Map<String, dynamic>? data() => database.stored;
  @override
  SnapshotMetadata get metadata => _Metadata(database.pending);
}

// ignore: subtype_of_sealed_class
class _Document extends Fake implements DocumentReference<Map<String, dynamic>> {
  _Document(this.database, this.path);
  final _Database database;
  @override
  final String path;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _Collection(database, '${this.path}/$path');
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    if (database.failure != null) throw database.failure!;
    return _Snapshot(database);
  }
  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    if (database.failure != null) throw database.failure!;
    database.path = path;
    database.written = data;
    database.stored = {...data, 'accepted_at': Timestamp.now()};
  }
}

// ignore: subtype_of_sealed_class
class _Collection extends Fake implements CollectionReference<Map<String, dynamic>> {
  _Collection(this.database, this.path);
  final _Database database;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) => _Document(database, '$path/$id');
}

class _Database extends Fake implements FirebaseFirestore {
  Map<String, dynamic>? stored;
  Map<String, dynamic>? written;
  String? path;
  Object? failure;
  bool pending = false;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) => _Collection(this, path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  test('existing accounts remain exempt; only marked new profiles require consent', () {
    expect(LegalConsent.requiredFor({'character_created': true}), isFalse);
    expect(LegalConsent.requiredFor({'character_created': false}), isFalse);
    expect(LegalConsent.requiredFor({LegalConsent.requiredField: true}), isTrue);
  });

  test('both independent selections are required', () {
    for (final pair in [(false, false), (true, false), (false, true)]) {
      expect(LegalConsent.validationError(pair.$1, pair.$2), isNotNull);
      expect(() => LegalConsent.record(pair.$1, pair.$2), throwsArgumentError);
    }
    expect(LegalConsent.validationError(true, true), isNull);
  });

  test('versions and a server timestamp are saved in the owner-only consent document', () async {
    final db = _Database();
    expect(await LegalConsent.hasAccepted('new', firestore: db), isFalse);
    await LegalConsent.save('new', terms: true, privacy: true, firestore: db);
    expect(db.path, 'users/new/private/consent');
    expect(db.written, {
      'terms_version': LegalDocuments.terms.version,
      'privacy_version': LegalDocuments.privacy.version,
      'accepted_at': FieldValue.serverTimestamp(),
    });
    expect(await LegalConsent.hasAccepted('new', firestore: db), isTrue);
  });

  test('missing, outdated, and unacknowledged records cannot complete onboarding', () async {
    final db = _Database();
    for (final data in [
      <String, dynamic>{},
      {'terms_version': 'old', 'privacy_version': 'old', 'accepted_at': Timestamp.now()},
      {'terms_version': LegalDocuments.terms.version, 'privacy_version': LegalDocuments.privacy.version},
    ]) {
      db.stored = data;
      expect(await LegalConsent.hasAccepted('new', firestore: db), isFalse);
    }
    await LegalConsent.save('new', terms: true, privacy: true, firestore: db);
    db.pending = true;
    await expectLater(LegalConsent.hasAccepted('new', firestore: db), throwsStateError);
  });

  test('failed persistence does not claim acceptance or change prior data', () async {
    final db = _Database()..stored = {'terms_version': 'old'};
    db.failure = FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
    await expectLater(LegalConsent.save('new', terms: true, privacy: true, firestore: db),
        throwsA(isA<FirebaseException>()));
    expect(db.stored, {'terms_version': 'old'});
    expect(db.written, isNull);
  });

  testWidgets('document links preserve independent checkbox selections', (tester) async {
    bool terms = false, privacy = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, update) => LegalConsentControls(
        terms: terms, privacy: privacy,
        onTermsChanged: (v) => update(() => terms = v),
        onPrivacyChanged: (v) => update(() => privacy = v)),
    ))));
    expect(tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value), [false, false]);
    await tester.tap(find.text('Terms of Service'));
    await tester.pumpAndSettle();
    expect(find.byType(LegalDocumentScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(terms, isFalse);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(find.byType(LegalDocumentScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(terms, isTrue);
    expect(privacy, isFalse);
    await tester.tap(find.byType(Checkbox).last);
    await tester.pumpAndSettle();
    expect(privacy, isTrue);
  });

  for (final label in ['CREATE HERO', 'SIGN UP WITH GOOGLE']) {
    testWidgets('$label validates consent before attempting authentication', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SignupScreen()));
      final button = find.text(label).last;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Both selections are required to continue.'), findsOneWidget);
      expect(tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value), [false, false]);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('reading a document preserves signup fields and selections', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SignupScreen()));
    await tester.enterText(find.byType(TextField).first, 'HeroName');
    await tester.enterText(find.byType(TextField).at(1), 'hero@example.com');
    await tester.ensureVisible(find.byType(Checkbox).first);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Privacy Policy'));
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(find.byType(LegalDocumentScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, 'HeroName');
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text, 'hero@example.com');
    expect(tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value), [true, false]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
