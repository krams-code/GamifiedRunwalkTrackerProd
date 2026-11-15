import 'package:shared_preferences/shared_preferences.dart';
import 'duel_session_native.dart'
    if (dart.library.js_interop) 'duel_session_web.dart'
    as platform;

Future<String> restoreDuelSession(String uid, String fallback) async {
  final key = 'duel_session_$uid';
  if (platform.browser) return platform.restore(key, fallback);
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(key);
  if (existing != null && existing.isNotEmpty) return existing;
  if (!await prefs.setString(key, fallback)) {
    throw StateError('Could not retain activity session.');
  }
  return fallback;
}
