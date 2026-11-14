import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/hero_progress.dart';
import '../models/hero_roster.dart';

/// Private, distinct costume IDs in successful equip order (newest first).
abstract final class CostumeUsage {
  static const field = 'costume_usage_order';

  static DocumentReference<Map<String, dynamic>> ref(String uid,
      {FirebaseFirestore? firestore}) =>
      (firestore ?? FirebaseFirestore.instance).collection('users').doc(uid)
          .collection('private').doc('wardrobe');

  static List<String> history(Object? value) => value is List
      ? value.whereType<String>().where((id) => heroById(id) != null).toSet().toList()
      : <String>[];

  static List<HeroDef> ordered(List<HeroDef> available, String equipped, Object? usage) {
    final byId = {for (final h in available) h.id: h};
    final ids = <String>{...history(usage), equipped, ...byId.keys};
    return [for (final id in ids) if (byId[id] case final h?) h];
  }

  /// The profile change and its recency entry either both commit or both fail.
  /// Read the latest profile on every retry so another device cannot lose order.
  static Future<bool> saveLook(DocumentReference<Map<String, dynamic>> user,
      Map<String, dynamic> Function(Map<String, dynamic>) changes,
      {FirebaseFirestore? firestore}) {
    final db = firestore ?? user.firestore;
    return db.runTransaction((transaction) async {
      final snapshot = await transaction.get(user);
      final profile = snapshot.data();
      if (profile == null) throw StateError('Your profile was not found.');
      final update = changes(profile);
      if (update.isEmpty) return false;
      final previous = hasChosenHero(profile) ? heroIdOf(profile) : null;
      final next = update['hero_id'];
      final switched = next is String && next != previous;
      if (switched) {
        if (heroById(next) == null) throw StateError('Unknown costume.');
        final wardrobe = ref(user.id, firestore: db);
        final saved = await transaction.get(wardrobe);
        final order = <String>{next, if (previous != null) previous,
          ...history(saved.data()?[field])}.toList();
        transaction.set(wardrobe, {field: order}, SetOptions(merge: true));
      }
      transaction.update(user, update);
      return switched;
    });
  }

  static Future<bool> equip(DocumentReference<Map<String, dynamic>> user, HeroDef hero,
      {FirebaseFirestore? firestore}) => saveLook(user, (profile) {
    if (hasChosenHero(profile) && heroIdOf(profile) == hero.id) return {};
    if (!isHeroUnlocked(hero, HeroProgress.fromData(profile))) {
      throw StateError('This costume is not unlocked.');
    }
    return {'hero_id': hero.id, 'owned_heroes': FieldValue.arrayUnion([hero.id])};
  }, firestore: firestore);
}
