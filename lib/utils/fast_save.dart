import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'quick_get.dart';

/// INSTANT SAVES.
///
/// The app keeps listening to the player's own document, so the copy on the
/// phone is always up to date. Reading that copy is instant; asking the
/// server first costs a full round trip (often 0.5-2 s on mobile data).
/// The server rules still check every save, so nothing can be cheated.
Future<DocumentSnapshot<Map<String, dynamic>>> localFirst(
    DocumentReference<Map<String, dynamic>> ref) async {
  try {
    final s = await ref.get(const GetOptions(
        source: Source.cache,
        serverTimestampBehavior: ServerTimestampBehavior.estimate));
    if (s.exists) return s;
  } catch (_) {/* not on the phone yet: ask the server */}
  return quickDoc(ref);
}

/// Start [write] without waiting for the server's answer. Firestore shows the
/// change on screen at once; if the server refuses it later, Firestore puts
/// the old values back by itself and [onRefused] runs (to tell the player).
void saveInBackground(Future<void> write, void Function(Object e) onRefused) {
  write.catchError((Object e) {
    debugPrint('save refused by the server: $e');
    onRefused(e);
  });
}
