import 'package:cloud_firestore/cloud_firestore.dart';

/// Reads that never leave a screen spinning. Ask the server first; if it has
/// not answered within [wait] (slow or stalled connection, common on Safari),
/// use the copy already on the phone instead.
const Duration kQuickWait = Duration(seconds: 8);

Future<DocumentSnapshot<Map<String, dynamic>>> quickDoc(
    DocumentReference<Map<String, dynamic>> ref,
    {Duration wait = kQuickWait}) async {
  try {
    return await ref.get().timeout(wait);
  } catch (_) {
    return ref.get(const GetOptions(source: Source.cache));
  }
}

Future<QuerySnapshot<Map<String, dynamic>>> quickQuery(
    Query<Map<String, dynamic>> query,
    {Duration wait = kQuickWait}) async {
  try {
    return await query.get().timeout(wait);
  } catch (_) {
    return query.get(const GetOptions(source: Source.cache));
  }
}
