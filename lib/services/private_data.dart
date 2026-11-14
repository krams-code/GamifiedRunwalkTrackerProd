import '../utils/quick_get.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/hero_roster.dart' show genderKey;

/// Data only the player can see: users/{uid}/private/body
///   { email, height_cm, weight_kg }
///
/// Everything in users/{uid} itself is visible to other players (leaderboard,
/// friend cards), so personal and health data must never be stored there.
abstract final class PrivateData {
  /// Fields that used to live on the public user doc.
  static const List<String> fields = ['email', 'height_cm', 'weight_kg'];

  /// Private values take precedence over the legacy public measurements.
  static Map<String, dynamic> profileData(
      Map<String, dynamic> user, Map<String, dynamic> body) => {
        ...user,
        for (final f in fields)
          if (body[f] != null) f: body[f],
      };

  static bool profileComplete(Map<String, dynamic> data) {
    final height = data['height_cm'];
    final weight = data['weight_kg'];
    return data['character_created'] == true &&
        genderKey(data['gender']) != null &&
        height is num && height.isFinite && height >= 100 && height <= 250 &&
        weight is num && weight.isFinite && weight >= 25 && weight <= 300;
  }

  /// Unlike optional profile reads, onboarding must not hide a read failure.
  static Future<Map<String, dynamic>> readProfile(String uid) async {
    final user = await FirebaseFirestore.instance
        .collection('users').doc(uid).get().timeout(kQuickWait);
    if (!user.exists || user.metadata.hasPendingWrites) {
      throw StateError('Your account is still being saved. Please retry.');
    }
    final body = await ref(uid).get().timeout(kQuickWait);
    if (body.metadata.hasPendingWrites) {
      throw StateError('Your profile is still being saved. Please retry.');
    }
    return profileData(user.data()!, body.data() ?? {});
  }

  static DocumentReference<Map<String, dynamic>> ref(String uid) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('private')
          .doc('body');

  static Future<Map<String, dynamic>> load(String uid) async {
    try {
      return (await quickDoc(ref(uid))).data() ?? <String, dynamic>{};
    } catch (e) {
      debugPrint('private data read: $e');
      return <String, dynamic>{};
    }
  }

  /// Older accounts kept email / height / weight on the public doc: move them
  /// to the private doc once and remove them from the public one.
  static Future<void> migrate(String uid) async {
    try {
      final userRef = FirebaseFirestore.instance.collection('users').doc(uid);
      final d = (await userRef.get()).data();
      if (d == null || !fields.any(d.containsKey)) return;
      final body = (await ref(uid).get()).data() ?? {};
      final batch = FirebaseFirestore.instance.batch();
      batch.set(
        ref(uid),
        {
          for (final f in fields)
            if (d[f] != null && body[f] == null) f: d[f],
        },
        SetOptions(merge: true),
      );
      batch.update(userRef, {for (final f in fields) f: FieldValue.delete()});
      await batch.commit();
    } catch (e) {
      debugPrint('private data migration: $e');
    }
  }
}
