import 'package:web/web.dart' as web;

const browser = true;
String restore(String key, String fallback) {
  // Per tab: refresh restores ownership; another tab cannot steal a live run.
  final storage = web.window.sessionStorage;
  final existing = storage.getItem(key);
  if (existing != null && existing.isNotEmpty) return existing;
  storage.setItem(key, fallback);
  return fallback;
}
