import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'friends_service.dart';

/// One shared inbox. Only unread time ranges have message listeners.
class ChatInbox extends ChangeNotifier {
  ChatInbox._();
  static final I = ChatInbox._();
  String? uid, openChat;
  bool foreground = true;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _chats;
  Timer? _retry;
  final _messages =
      <String, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>{};
  final _ranges = <String, Timestamp>{};
  final _counts = <String, int>{};
  final _announced = <String, Timestamp>{};
  bool _initialChats = true;
  int arrival = 0;
  String? arrivalChat;

  int get total => _counts.values.fold(0, (a, b) => a + b);
  int unread(String other) =>
      uid == null ? 0 : (_counts[FriendsService.chatId(uid!, other)] ?? 0);
  int countFor(String id) => _counts[id] ?? 0;

  void start(String? user) {
    if (uid == user) return;
    _retry?.cancel();
    _chats?.cancel();
    for (final sub in _messages.values) {
      sub.cancel();
    }
    _messages.clear();
    _ranges.clear();
    _counts.clear();
    _announced.clear();
    uid = user;
    openChat = null;
    arrivalChat = null;
    _initialChats = true;
    notifyListeners();
    if (user == null) return;
    _watch(user);
  }

  void _watch(String user) {
    _chats?.cancel();
    _chats = FriendsService.chats
        .where('members', arrayContains: user)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snapshot) {
            if (uid != user ||
                snapshot.metadata.isFromCache ||
                snapshot.metadata.hasPendingWrites)
              return;
            final ids = snapshot.docs.map((d) => d.id).toSet();
            for (final id in _ranges.keys.toList()) {
              if (!ids.contains(id)) _clear(id);
            }
            for (final doc in snapshot.docs) {
              final data = doc.data();
              final last = data['last_at'];
              final rawRead = (data['read'] as Map?)?[user];
              final read = rawRead is Timestamp ? rawRead : Timestamp(0, 0);
              // Seed existing conversations once, using server timestamps rather
              // than the phone clock. New messages can then trigger immediately.
              if (_initialChats && last is Timestamp) _announced[doc.id] = last;
              if (last is! Timestamp || last.compareTo(read) <= 0) {
                _clear(doc.id);
                continue;
              }
              if (_ranges[doc.id] == read) continue;
              _messages.remove(doc.id)?.cancel();
              _ranges[doc.id] = read;
              // A single timestamp range uses the existing automatic field index.
              _messages[doc.id] = doc.reference
                  .collection('messages')
                  .where('ts', isGreaterThan: read)
                  .orderBy('ts')
                  .snapshots(includeMetadataChanges: true)
                  .listen(
                    (messages) {
                      if (uid != user ||
                          _ranges[doc.id] != read ||
                          messages.metadata.isFromCache ||
                          messages.metadata.hasPendingWrites)
                        return;
                      final incoming = messages.docs
                          .where((m) => m.data()['from'] != user)
                          .toList();
                      _counts[doc.id] = incoming.length;
                      if (incoming.isNotEmpty) {
                        final latest = incoming.last.data()['ts'];
                        if (latest is Timestamp &&
                            (_announced[doc.id] == null ||
                                latest.compareTo(_announced[doc.id]!) > 0)) {
                          _announced[doc.id] = latest;
                          if (foreground && openChat != doc.id) {
                            arrival++;
                            arrivalChat = doc.id;
                          }
                        }
                      }
                      notifyListeners();
                    },
                    onError: (Object error) {
                      if (uid == user && _ranges[doc.id] == read) {
                        debugPrint('Unread chat listener failed: $error');
                        _messages.remove(doc.id)?.cancel();
                        _ranges.remove(doc.id);
                        _counts.remove(doc.id);
                        notifyListeners();
                        _scheduleRetry(user);
                      }
                    },
                  );
            }
            _initialChats = false;
            notifyListeners();
          },
          onError: (Object error) {
            debugPrint('Chat inbox listener failed: $error');
            _scheduleRetry(user);
          },
        );
  }

  void _scheduleRetry(String user) {
    if (uid != user || (_retry?.isActive ?? false)) return;
    _retry = Timer(const Duration(seconds: 10), () {
      if (uid == user) _watch(user);
    });
  }

  void _clear(String id) {
    _messages.remove(id)?.cancel();
    _ranges.remove(id);
    _counts.remove(id);
  }
}
