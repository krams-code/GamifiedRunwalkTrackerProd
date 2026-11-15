import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hakbanghero/services/usernames.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../firebase_options.dart';

import '../models/outfit_catalog.dart';
import 'legal_consent.dart';

/// Result of a Google sign-in attempt.
class GoogleAuthResult {
  const GoogleAuthResult({this.user, this.message, this.cancelled = false});
  final User? user;
  final String? message;
  final bool cancelled;
  bool get ok => user != null;
}

/// Browser sign-in uses Firebase's popup. Native Google authentication uses
/// the Google SDK and exchanges its ID token for a Firebase credential.
class GoogleAuth {
  GoogleAuth._();
  static final inProgress = ValueNotifier<bool>(false);
  static final Map<String, Future<void>> _profiles = {};
  static Future<void>? _nativeInit;

  static Future<OAuthCredential> nativeCredential() async {
    await (_nativeInit ??= GoogleSignIn.instance
        .initialize(serverClientId: DefaultFirebaseOptions.googleServerClientId)
        .catchError((Object e) {
          _nativeInit = null;
          throw e;
        }));
    final account = await GoogleSignIn.instance.authenticate();
    final token = account.authentication.idToken;
    if (token == null) throw StateError('Google did not confirm this sign-in.');
    return GoogleAuthProvider.credential(idToken: token);
  }

  static Future<GoogleAuthResult> signIn() async {
    final provider = GoogleAuthProvider()..addScope('email');
    try {
      final auth = FirebaseAuth.instance;
      final cred = kIsWeb
          ? await auth.signInWithPopup(provider)
          : await auth.signInWithCredential(await nativeCredential());
      final user = cred.user;
      if (user == null) {
        return const GoogleAuthResult(
          message: 'Google sign-in failed. Try again.',
        );
      }
      return GoogleAuthResult(user: user);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return const GoogleAuthResult(
          cancelled: true,
          message: 'Google sign-in cancelled.',
        );
      }
      debugPrint('Native Google sign-in: ${e.code.name}');
      return const GoogleAuthResult(
        message:
            'Google sign-in could not be completed. Check your connection or use email sign-in.',
      );
    } on FirebaseAuthException catch (e) {
      const cancelCodes = {
        'canceled',
        'cancelled',
        'popup-closed-by-user',
        'cancelled-popup-request',
        'web-context-canceled',
        'web-context-cancelled',
      };
      if (cancelCodes.contains(e.code)) {
        return const GoogleAuthResult(
          cancelled: true,
          message: 'Google sign-in cancelled.',
        );
      }
      if (e.code == 'account-exists-with-different-credential') {
        return const GoogleAuthResult(
          message:
              'This email is already registered with a password. Log in with your email instead.',
        );
      }
      if (e.code == 'network-request-failed') {
        return const GoogleAuthResult(
          message: 'No internet connection. Check your network and try again.',
        );
      }
      return GoogleAuthResult(
        message: e.message ?? 'Google sign-in failed. Try again.',
      );
    } catch (_) {
      return const GoogleAuthResult(
        message: 'Google sign-in failed. Try again.',
      );
    }
  }

  /// Creates the users/{uid} document for a first-time account (idempotent).
  static Future<void> ensureUserDoc(
    User user,
    String username, {
    String? gender,
    bool termsAccepted = false,
    bool privacyAcknowledged = false,
    FirebaseFirestore? firestore,
  }) {
    return _profiles.putIfAbsent(
      user.uid,
      () =>
          _ensureUserDoc(
            user,
            username,
            gender: gender,
            termsAccepted: termsAccepted,
            privacyAcknowledged: privacyAcknowledged,
            firestore: firestore,
          ).whenComplete(() {
            _profiles.remove(user.uid);
          }),
    );
  }

  static Future<void> _ensureUserDoc(
    User user,
    String username, {
    String? gender,
    required bool termsAccepted,
    required bool privacyAcknowledged,
    FirebaseFirestore? firestore,
  }) async {
    final db = firestore ?? FirebaseFirestore.instance;
    final ref = db.collection('users').doc(user.uid);
    // Name ownership and initial profile commit together. A concurrent restore
    // can never reset an account that has already finished onboarding.
    final clean = username.trim().replaceAll(RegExp(r'[^A-Za-z0-9_ ]'), '');
    final base = clean.length < 3
        ? 'Hero'
        : clean.substring(0, clean.length.clamp(0, 16));
    for (var attempt = 0; attempt < 8; attempt++) {
      final suffix =
          '${user.uid.hashCode.abs() % 10000}${attempt == 0 ? '' : attempt}';
      final name = attempt == 0
          ? base
          : '${base.substring(0, base.length.clamp(0, 10))}$suffix';
      final reserved = await db.runTransaction<bool>((txn) async {
        if ((await txn.get(ref)).exists) return true;
        final nameRef = db.collection('usernames').doc(Usernames.key(name));
        final owner = await txn.get(nameRef);
        if (owner.exists && owner.data()?['uid'] != user.uid) return false;
        if (!owner.exists) txn.set(nameRef, {'uid': user.uid, 'name': name});
        txn.set(ref, {
          'username': name,
          'username_key': Usernames.key(name),
          'gender': gender,
          'level': 1,
          'xp': 0,
          'coins': 100,
          'heroic_souls': 0,
          'total_km': 0.0,
          'total_steps': 0,
          'total_sessions': 0,
          'created_at': FieldValue.serverTimestamp(),
          'character_created': false,
          LegalConsent.requiredField: true,
          'skin_tone': '#E0AC69',
          ...StarterPack.toFirestore(),
          'owned_items': StarterPack.ownedItems,
          'hair_color': '#1A1A1A',
          'body_tier': 'average',
        });
        // private: only this player can read it
        txn.set(ref.collection('private').doc('body'), {
          'email': user.email,
        }, SetOptions(merge: true));
        if (termsAccepted && privacyAcknowledged) {
          txn.set(
            LegalConsent.ref(user.uid, firestore: db),
            LegalConsent.record(true, true),
          );
        }
        return true;
      });
      if (reserved) return;
    }
    throw StateError('Choose another hero name to finish your account.');
  }
}
