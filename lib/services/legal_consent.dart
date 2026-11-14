import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/legal_documents.dart';

abstract final class LegalConsent {
  static const requiredField = 'legal_consent_required';

  /// Only newly created profiles opt into this flow. Older accounts stay exempt.
  static bool requiredFor(Map<String, dynamic> profile) =>
      profile[requiredField] == true;

  static String? validationError(bool terms, bool privacy) {
    if (!terms && !privacy) return 'Agree to the Terms of Service and acknowledge the Privacy Policy to continue.';
    if (!terms) return 'Agree to the Terms of Service to continue.';
    if (!privacy) return 'Acknowledge that you have read the Privacy Policy to continue.';
    return null;
  }

  static DocumentReference<Map<String, dynamic>> ref(String uid,
      {FirebaseFirestore? firestore}) =>
      (firestore ?? FirebaseFirestore.instance).collection('users').doc(uid)
          .collection('private').doc('consent');

  static Map<String, dynamic> record(bool terms, bool privacy) {
    final error = validationError(terms, privacy);
    if (error != null) throw ArgumentError(error);
    return {
      'terms_version': LegalDocuments.terms.version,
      'privacy_version': LegalDocuments.privacy.version,
      'accepted_at': FieldValue.serverTimestamp(),
    };
  }

  static bool isCurrent(Map<String, dynamic>? data) =>
      data?['terms_version'] == LegalDocuments.terms.version &&
      data?['privacy_version'] == LegalDocuments.privacy.version &&
      data?['accepted_at'] is Timestamp;

  static Future<bool> hasAccepted(String uid, {FirebaseFirestore? firestore}) async {
    final doc = await ref(uid, firestore: firestore).get()
        .timeout(const Duration(seconds: 8));
    if (doc.metadata.hasPendingWrites) {
      throw StateError('Your document acceptance is still being saved. Please retry.');
    }
    return isCurrent(doc.data());
  }

  static Future<void> save(String uid, {required bool terms, required bool privacy,
      FirebaseFirestore? firestore}) async {
    await ref(uid, firestore: firestore).set(record(terms, privacy))
        .timeout(const Duration(seconds: 30));
  }
}
