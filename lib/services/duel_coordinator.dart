import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/duel_policy.dart';
import 'friends_service.dart';
import 'presence.dart';

/// One account/session listener across all routes. Slots retain the last duel
/// reference after release, so a reconnecting client can read its final result.
class DuelCoordinator with WidgetsBindingObserver, ChangeNotifier {
  DuelCoordinator._();
  static final I = DuelCoordinator._();
  final String session = '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 30)}';
  String? uid, challengeId, roomId;
  Map<String, dynamic>? challenge, slot;
  bool soloBusy = false;
  bool foreground = true;
  bool _working = false;
  bool _releasingSolo = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _slotSub, _duelSub;
  StreamSubscription<User?>? _authSub;
  Timer? _timer;
  Future<void> Function(String)? openRoom;
  bool get ownsSession => slot?['session_id'] == session;

  Future<void> start(String user) async {
    if (uid == user) return;
    stop();
    uid = user;
    foreground = ![AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.detached]
        .contains(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
    _authSub = FirebaseAuth.instance.authStateChanges().listen((u) {
      if (u?.uid != uid) stop();
    });
    _slotSub = FriendsService.activity(user).snapshots().listen((s) {
      if (uid != user) return;
      slot = s.data();
      final next = slot?['challenge_id'] as String?;
      if (next != challengeId) {
        _duelSub?.cancel();
        challengeId = next; challenge = null;
        if (next != null && next.isNotEmpty) {
          _duelSub = FriendsService.challenges.doc(next).snapshots(includeMetadataChanges: true).listen((d) {
            if (uid != user || challengeId != next || d.metadata.hasPendingWrites || d.metadata.isFromCache) return;
            challenge = d.data(); notifyListeners();
          }, onError: (Object _) {});
        }
      }
      notifyListeners();
    }, onError: (Object _) {});
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    await _heartbeat();
  }

  void stop() {
    _timer?.cancel(); _slotSub?.cancel(); _duelSub?.cancel(); _authSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    uid = null; challengeId = null; challenge = null; slot = null;
    soloBusy = false; roomId = null; _working = false; _releasingSolo = false;
    notifyListeners();
  }

  int _seconds = 0;
  Future<void> _tick() async {
    if (uid == null || _working || (!foreground && !soloBusy && roomId == null)) return;
    _working = true;
    try {
      final id = challengeId;
      if (id != null && challenge != null && !DuelPolicy.terminal.contains(challenge!['status'])) {
        if (DuelPolicy.expired(challenge!, DateTime.now()) || challenge!['protocol'] != DuelPolicy.version || _seconds % 30 == 0) {
          await FriendsService.expireChallenge(id);
        }
      } else if (id != null && roomId == null && slot?['kind'] == 'duel') {
        await releaseRoom(id);
      }
      if (_releasingSolo) await endSolo();
      if (++_seconds % 30 == 0 || slot == null) await _heartbeat();
    } catch (_) {
      // The next tick retries. Never claim a transition succeeded offline.
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  Future<void> _heartbeat() async {
    final user = uid;
    if (user == null) return;
    await FirebaseFirestore.instance.runTransaction((txn) async {
      final ref = FriendsService.activity(user);
      final d = (await txn.get(ref)).data();
      if (uid != user) return;
      Map<String, dynamic>? last;
      if (d?['kind'] == 'duel') {
        last = (await txn.get(FriendsService.challenges.doc(d!['challenge_id'] as String))).data();
      }
      final at = d?['updated_at'];
      final staleSolo = d?['kind'] == 'solo' && at is Timestamp &&
          DateTime.now().difference(at.toDate()).inSeconds >= DuelPolicy.presenceSeconds;
      if (d == null || d['kind'] == 'available' || staleSolo || (roomId == null && DuelPolicy.terminal.contains(last?['status']))) {
        txn.set(ref, {'kind': 'available', 'session_id': session,
          'challenge_id': d?['challenge_id'] ?? '', 'outcome_seen': d?['outcome_seen'] ?? '',
          'updated_at': FieldValue.serverTimestamp()});
      } else if (d['session_id'] == session) {
        txn.update(ref, {'updated_at': FieldValue.serverTimestamp()});
      }
    });
  }

  Future<bool> beginSolo() async {
    final user = uid;
    if (user == null || roomId != null) return false;
    if (soloBusy) return ownsSession && slot?['kind'] == 'solo';
    soloBusy = true; notifyListeners();
    try {
      await _heartbeat();
      await FirebaseFirestore.instance.runTransaction((txn) async {
        final ref = FriendsService.activity(user);
        final current = (await txn.get(ref)).data();
        if (current?['session_id'] != session) throw const DuelUnavailable('Another session is using this account.');
        final id = current?['challenge_id'] as String? ?? '';
        Map<String, dynamic>? duel;
        DocumentSnapshot<Map<String, dynamic>>? otherSlot;
        if (current?['kind'] == 'duel') {
          duel = (await txn.get(FriendsService.challenges.doc(id))).data();
          if (duel?['status'] != 'pending') throw const DuelUnavailable(DuelPolicy.busyMessage);
          final other = (duel!['participants'] as List).firstWhere((u) => u != user) as String;
          otherSlot = await txn.get(FriendsService.activity(other));
        }
        if (duel != null) {
          txn.update(FriendsService.challenges.doc(id), {'status': duel['to'] == user ? 'busy' : 'cancelled',
            'finished_at': FieldValue.serverTimestamp()});
          if (otherSlot?.data()?['challenge_id'] == id) {
            txn.update(otherSlot!.reference, {'kind': 'available', 'updated_at': FieldValue.serverTimestamp()});
          }
        }
        txn.update(ref, {'kind': 'solo', 'updated_at': FieldValue.serverTimestamp()});
      });
      Presence.I.holdActive(true);
      return true;
    } catch (_) {
      soloBusy = false; notifyListeners();
      return false;
    }
  }

  Future<void> endSolo() async {
    final user = uid;
    if (user == null) return;
    _releasingSolo = true;
    try {
      await FirebaseFirestore.instance.runTransaction((txn) async {
        final ref = FriendsService.activity(user);
        final d = (await txn.get(ref)).data();
        if (d?['session_id'] == session && d?['kind'] == 'solo') {
          txn.update(ref, {'kind': 'available', 'updated_at': FieldValue.serverTimestamp()});
        }
      });
      _releasingSolo = false;
      soloBusy = false; Presence.I.holdActive(false); notifyListeners();
    } catch (_) {
      // Keep the slot busy until release is acknowledged; retry on reconnect.
    }
  }

  Future<void> releaseRoom(String id) async {
    final user = uid;
    if (user == null) return;
    await FirebaseFirestore.instance.runTransaction((txn) async {
      final ref = FriendsService.activity(user);
      final d = (await txn.get(ref)).data();
      final duel = (await txn.get(FriendsService.challenges.doc(id))).data();
      if (d?['challenge_id'] == id && d?['kind'] == 'duel' && DuelPolicy.terminal.contains(duel?['status'])) {
        txn.update(ref, {'kind': 'available', 'updated_at': FieldValue.serverTimestamp()});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) _heartbeat().catchError((_) {});
    notifyListeners();
  }
}
