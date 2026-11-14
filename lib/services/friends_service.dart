import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/weekly.dart';
import 'run_saver.dart';
import '../models/duel_policy.dart';

/// Outcome of looking a friend code up (step 1 of adding a friend).
enum LookupStatus { found, notFound, self, already, pending, error }

class FriendLookup {
  final LookupStatus status;
  final String? uid;
  final Map<String, dynamic>? data; // their public profile, for the confirm card
  const FriendLookup(this.status, {this.uid, this.data});
}

/// My relationship with another player.
enum Relation { none, friend, sent, incoming, error }

/// Outcome of actually sending the request (step 2, after the player confirms).
enum AddResult { sent, accepted, cooldown, full, error }

/// Firestore layout (see firestore_round2.rules):
///   users/{uid}.friend_code                  "HERO-4F7K"
///   friend_codes/{code}                      { uid }          (lookup index)
///   friend_requests/{from}_{to}              { from, to, from_name, status }
///   users/{uid}/friends/{friendUid}          { name, since }  (written for BOTH)
///   challenges/{id}   LIVE duel: status pending -> lobby -> countdown -> active -> done
///                     (or declined / cancelled / forfeit / expired)
///                     { participants, from, to, distance_km, reward, status,
///                       ready{uid:bool}, progress{uid:km}, seen{uid:ts}, winner }
///   reports/{id}                             { reporter, reported, reason, note, recent[] }
///   chats/{minUid}_{maxUid}                  { members, last_text, last_from, last_at, read{uid} }
///   chats/{id}/messages/{mid}                { from, text, ts }
class FriendsService {
  FriendsService._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static DocumentReference<Map<String, dynamic>> user(String uid) =>
      _db.collection('users').doc(uid);
  static CollectionReference<Map<String, dynamic>> friends(String uid) =>
      user(uid).collection('friends');
  static CollectionReference<Map<String, dynamic>> get requests =>
      _db.collection('friend_requests');
  static CollectionReference<Map<String, dynamic>> get challenges =>
      _db.collection('challenges');
  static CollectionReference<Map<String, dynamic>> get chats =>
      _db.collection('chats');

  // ───────────────────────── friend code ─────────────────────────

  // no 0/O/1/I so codes are easy to read out loud
  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// The player's own code; created (and reserved uniquely) on first use.
  static Future<String> ensureCode(String uid) async {
    final snap = await user(uid).get();
    final existing = snap.data()?['friend_code'] as String?;
    if (existing != null && existing.isNotEmpty) return existing;

    final rng = Random.secure();
    for (var i = 0; i < 8; i++) {
      final code =
          'HERO-${List.generate(4, (_) => _alphabet[rng.nextInt(_alphabet.length)]).join()}';
      final ref = _db.collection('friend_codes').doc(code);
      try {
        await _db.runTransaction((txn) async {
          if ((await txn.get(ref)).exists) throw 'taken';
          txn.set(ref, {'uid': uid});
          txn.set(user(uid), {'friend_code': code}, SetOptions(merge: true));
        });
        return code;
      } catch (_) {/* collision or network: try another code */}
    }
    return '';
  }

  // ───────────────────────── add a friend (2 steps) ─────────────────────────

  /// Step 1: validate the code and fetch the profile to show on a confirm card.
  static Future<FriendLookup> lookup(String me, String rawCode) async {
    var code = rawCode.trim().toUpperCase().replaceAll(' ', '');
    if (code.isEmpty) return const FriendLookup(LookupStatus.notFound);
    if (!code.startsWith('HERO-')) code = 'HERO-$code';
    try {
      final c = await _db.collection('friend_codes').doc(code).get();
      final other = c.data()?['uid'] as String?;
      if (!c.exists || other == null) return const FriendLookup(LookupStatus.notFound);
      if (other == me) return const FriendLookup(LookupStatus.self);

      final profile = (await user(other).get()).data();
      if (profile == null) return const FriendLookup(LookupStatus.notFound);
      // they blocked me: look exactly like "no such user"
      final theirBlocks = (profile['blocked_uids'] as List?)?.whereType<String>() ?? const [];
      if (theirBlocks.contains(me)) return const FriendLookup(LookupStatus.notFound);

      if ((await friends(me).doc(other).get()).exists) {
        return FriendLookup(LookupStatus.already, uid: other, data: profile);
      }
      final mine = await requests.doc('${me}_$other').get();
      if (mine.exists && mine.data()?['status'] == 'pending') {
        return FriendLookup(LookupStatus.pending, uid: other, data: profile);
      }
      return FriendLookup(LookupStatus.found, uid: other, data: profile);
    } catch (_) {
      return const FriendLookup(LookupStatus.error);
    }
  }

  /// How I stand with [other] (for the Add Friend button on a player card).
  static Future<Relation> relation(String me, String other) async {
    try {
      if ((await friends(me).doc(other).get()).exists) return Relation.friend;
      final sent = await requests.doc('${me}_$other').get();
      if (sent.exists && sent.data()?['status'] == 'pending') return Relation.sent;
      final got = await requests.doc('${other}_$me').get();
      if (got.exists && got.data()?['status'] == 'pending') return Relation.incoming;
      return Relation.none;
    } catch (_) {
      return Relation.error;
    }
  }

  /// Step 2: the player confirmed. If they already asked me, this just accepts.
  static Future<AddResult> requestTo({
    required String me,
    required String myName,
    required String otherUid,
  }) async {
    try {
      // friend list limit (like most games: keeps lists and live data fast)
      final mine = await friends(me).count().get();
      if ((mine.count ?? 0) >= maxFriends) return AddResult.full;

      // adding someone you blocked un-blocks them
      await user(me).update({'blocked_uids': FieldValue.arrayRemove([otherUid])}).catchError((_) {});

      final reverse = await requests.doc('${otherUid}_$me').get();
      if (reverse.exists && reverse.data()?['status'] == 'pending') {
        await accept(me: me, myName: myName, fromUid: otherUid);
        return AddResult.accepted;
      }
      // they said no: no new request for 24 hours (no request spam)
      final own = await requests.doc('${me}_$otherUid').get();
      final od = own.data();
      if (od != null && od['status'] == 'declined') {
        final at = (od['declined_at'] as Timestamp?)?.toDate();
        if (at != null && DateTime.now().difference(at) < declineCooldown) {
          return AddResult.cooldown;
        }
      }
      await requests.doc('${me}_$otherUid').set({
        'from': me,
        'to': otherUid,
        'from_name': myName,
        'status': 'pending',
        'created_at': FieldValue.serverTimestamp(),
      });
      return AddResult.sent;
    } catch (_) {
      return AddResult.error;
    }
  }

  static Future<void> accept({
    required String me,
    required String myName,
    required String fromUid,
  }) async {
    final theirName =
        (await user(fromUid).get()).data()?['username'] as String? ?? 'Hero';
    final batch = _db.batch();
    batch.set(friends(me).doc(fromUid),
        {'name': theirName, 'since': FieldValue.serverTimestamp()});
    batch.set(friends(fromUid).doc(me),
        {'name': myName, 'since': FieldValue.serverTimestamp()});
    batch.update(requests.doc('${fromUid}_$me'), {'status': 'accepted'});
    await batch.commit();
  }

  /// Most friends one player can have.
  static const int maxFriends = 100;

  /// After a "no", the same player can't ask again for this long.
  static const Duration declineCooldown = Duration(hours: 24);

  /// Kept as "declined" (not deleted) so the sender can't re-send at once.
  static Future<void> decline(String fromUid, String me) =>
      requests.doc('${fromUid}_$me').update({
        'status': 'declined',
        'declined_at': FieldValue.serverTimestamp(),
      });

  static Future<void> unfriend(String me, String other) async {
    final batch = _db.batch();
    batch.delete(friends(me).doc(other));
    batch.delete(friends(other).doc(me));
    await batch.commit();
  }

  /// Unfriend + hide from now on (they can no longer find me by code).
  static Future<void> block(String me, String other) async {
    await user(me).set(
        {'blocked_uids': FieldValue.arrayUnion([other])}, SetOptions(merge: true));
    await unfriend(me, other);
  }

  static Future<void> report({
    required String me,
    required String reported,
    required String reportedName,
    required String reason,
    String note = '',
    List<String> recent = const [],
  }) {
    return _db.collection('reports').add({
      'reporter': me,
      'reported': reported,
      'reported_name': reportedName,
      'reason': reason,
      'note': note.length > 300 ? note.substring(0, 300) : note,
      'recent': recent.take(8).toList(), // last messages, as evidence
      'created_at': FieldValue.serverTimestamp(),
      'status': 'open',
    });
  }

  // ───────────────────────── LIVE duels ─────────────────────────
  //
  // pending   invite sent
  // lobby     accepted; both players open the room and press READY
  // countdown both ready -> synchronized 3-2-1-GO
  // active    both are running in the room; progress syncs live
  // done      someone reached the distance (winner set)
  // forfeit   a player left mid-race (the other claims the win)
  // declined / cancelled / expired

  /// distance (km) -> Coins the winner earns.
  static const Map<int, int> rewardFor = {1: 200, 3: 400, 5: 600, 10: 1000};
  static const int lobbyMinutes = 15;
  static const int countdownSeconds = 5;

  static DocumentReference<Map<String, dynamic>> activity(String uid) =>
      _db.collection('player_activity').doc(uid);
  static DocumentReference<Map<String, dynamic>> cooldown(String from, String to) =>
      _db.collection('duel_cooldowns').doc(from).collection('recipients').doc(to);

  static String duelError(Object e) => e is DuelUnavailable ? e.message :
      'Could not update the duel. Check your connection and try again.';

  static bool _leased(Map<String, dynamic>? slot) {
    final at = slot?['updated_at'];
    return at is Timestamp && DateTime.now().difference(at.toDate()).inSeconds < DuelPolicy.presenceSeconds;
  }

  static Future<List<DocumentSnapshot<Map<String, dynamic>>>> _slots(Transaction txn, Map<String, dynamic> d) async =>
      [for (final uid in (d['participants'] as List).cast<String>()) await txn.get(activity(uid))];

  static void _release(Transaction txn, String id, List<DocumentSnapshot<Map<String, dynamic>>> slots) {
    for (final slot in slots) {
      if (slot.data()?['challenge_id'] == id && slot.data()?['kind'] == 'duel') {
        txn.update(slot.reference, {'kind': 'available', 'updated_at': FieldValue.serverTimestamp()});
      }
    }
  }

  static Future<void> _availablePlayers(Transaction txn, Map<String, dynamic> d, String id) async {
    for (final uid in (d['participants'] as List).cast<String>()) {
      final p = await txn.get(_db.collection('presence').doc(uid));
      final a = await txn.get(activity(uid));
      if (!DuelPolicy.fresh(p.data(), DateTime.now()) || !_leased(a.data())) {
        throw const DuelUnavailable('This player is offline or their availability could not be confirmed.');
      }
      if (a.data()?['kind'] != 'duel' || a.data()?['challenge_id'] != id) {
        throw const DuelUnavailable(DuelPolicy.busyMessage);
      }
    }
  }

  /// Reserve both invitation slots in the same commit as the invitation.
  static Future<DocumentReference<Map<String, dynamic>>> sendChallenge({
    required String me, required String myName, required String otherUid,
    required String otherName, required int km, required String session,
  }) async {
    if (me == otherUid || !rewardFor.containsKey(km)) throw const DuelUnavailable('Choose an eligible friend and distance.');
    final ref = challenges.doc();
    await _db.runTransaction((txn) async {
      final wait = (await txn.get(cooldown(me, otherUid))).data()?['declined_at'];
      if (wait is Timestamp) {
        final remaining = wait.toDate().add(const Duration(seconds: DuelPolicy.cooldownSeconds)).difference(DateTime.now());
        if (remaining > Duration.zero) {
          throw DuelUnavailable('This player declined your duel invitation. Please try again in ${remaining.inMinutes + 1} minutes.');
        }
      }
      final slots = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final uid in [me, otherUid]) {
        final p = await txn.get(_db.collection('presence').doc(uid));
        final a = await txn.get(activity(uid));
        if (!DuelPolicy.fresh(p.data(), DateTime.now()) || !_leased(a.data())) {
          throw const DuelUnavailable('This player is offline or their availability could not be confirmed.');
        }
        if (a.data()?['kind'] != 'available') throw const DuelUnavailable(DuelPolicy.busyMessage);
        if (uid == me && a.data()?['session_id'] != session) {
          throw const DuelUnavailable('Another session is using this account.');
        }
        slots.add(a);
      }
      txn.set(ref, {
        'protocol': DuelPolicy.version, 'participants': [me, otherUid],
        'from': me, 'to': otherUid, 'from_name': myName, 'to_name': otherName,
        'distance_km': km, 'reward': rewardFor[km], 'status': 'pending',
        'ready': {me: false, otherUid: false}, 'progress': {me: 0.0, otherUid: 0.0},
        'seen': {}, 'finals': {}, 'created_at': FieldValue.serverTimestamp(),
      });
      for (final a in slots) {
        txn.update(a.reference, {'kind': 'duel', 'challenge_id': ref.id, 'updated_at': FieldValue.serverTimestamp()});
      }
    });
    return ref;
  }

  static Future<bool> acknowledgeChallenge(String id, String me, String session) => _db.runTransaction((txn) async {
    final ref = challenges.doc(id);
    final d = (await txn.get(ref)).data();
    final slot = (await txn.get(activity(me))).data();
    if (d == null || d['protocol'] != DuelPolicy.version || d['status'] != 'pending' ||
        d['to'] != me || DuelPolicy.expired(d, DateTime.now()) || slot?['session_id'] != session ||
        slot?['kind'] != 'duel' || slot?['challenge_id'] != id) { return false; }
    if (d['delivered_at'] != null) return d['delivery_session'] == session;
    txn.update(ref, {'delivered_at': FieldValue.serverTimestamp(), 'delivery_session': session});
    return true;
  });

  static Future<void> declineChallenge(String id) => _closeChallenge(id, 'declined');

  static Future<void> acceptChallenge(String id, String me, String session) => _db.runTransaction((txn) async {
    final ref = challenges.doc(id);
    final d = (await txn.get(ref)).data();
    if (d == null || d['status'] != 'pending' || d['to'] != me ||
        d['delivery_session'] != session || d['delivered_at'] == null || DuelPolicy.expired(d, DateTime.now())) {
      throw const DuelUnavailable('This invitation is no longer available.');
    }
    await _availablePlayers(txn, d, id);
    txn.update(ref, {'status': 'lobby', 'accepted_at': FieldValue.serverTimestamp()});
  });

  static Future<void> setReady(String id, String me, bool ready) => _db.runTransaction((txn) async {
    final ref = challenges.doc(id);
    final d = (await txn.get(ref)).data();
    if (d == null || d['status'] != 'lobby' || DuelPolicy.expired(d, DateTime.now())) {
      throw const DuelUnavailable('This room is no longer available.');
    }
    await _availablePlayers(txn, d, id);
    txn.update(ref, {'ready.$me': ready, 'seen.$me': FieldValue.serverTimestamp()});
  });

  static Future<void> startCountdownIfReady(String id) => _db.runTransaction((txn) async {
    final ref = challenges.doc(id);
    final d = (await txn.get(ref)).data();
    if (d == null || d['status'] != 'lobby' || DuelPolicy.expired(d, DateTime.now())) return;
    if (!(d['participants'] as List).every((u) => (d['ready'] as Map? ?? {})[u] == true)) return;
    await _availablePlayers(txn, d, id);
    txn.update(ref, {'status': 'countdown', 'countdown_at': FieldValue.serverTimestamp()});
  });

  static Future<void> goActive(String id) => _db.runTransaction((txn) async {
    final ref = challenges.doc(id);
    final d = (await txn.get(ref)).data();
    if (d == null || d['status'] != 'countdown') return;
    final at = d['countdown_at'];
    if (at is! Timestamp || DateTime.now().difference(at.toDate()).inSeconds < countdownSeconds) return;
    await _availablePlayers(txn, d, id);
    txn.update(ref, {'status': 'active', 'started_at': FieldValue.serverTimestamp()});
  });

  static Future<void> pushProgress(String id, String me, double km) async {
    final batch = _db.batch();
    batch.update(challenges.doc(id), {
      'progress.$me': double.parse(km.toStringAsFixed(3)), 'seen.$me': FieldValue.serverTimestamp(),
    });
    batch.update(activity(me), {'updated_at': FieldValue.serverTimestamp()});
    await batch.commit();
  }

  static const double minPrizeKm = 0.2;
  static const int duelPrizesPerDay = 3;

  static int prizeFor(Map<String, dynamic> d, double myKm, {required bool finished}) {
    final reward = (d['reward'] as num?)?.toInt() ?? 0;
    if (finished) return reward;
    final dist = (d['distance_km'] as num?)?.toDouble() ?? 1;
    if (myKm < minPrizeKm || dist <= 0) return 0;
    return (reward * (myKm / dist).clamp(0.0, 1.0)).floor();
  }

  static Future<void> _payWin(Transaction txn, DocumentSnapshot<Map<String, dynamic>> ch,
      String me, double km, {required bool finished}) async {
    final d = ch.data()!;
    final ud = (await txn.get(user(me))).data() ?? <String, dynamic>{};
    final day = RunSaver.coinDay();
    final paidToday = (ud['duel_prize_day'] as num?)?.toInt() == day
        ? ((ud['duel_prizes_today'] as num?)?.toInt() ?? 0) : 0;
    final prize = paidToday >= duelPrizesPerDay ? 0 : RunSaver.capToday(ud, prizeFor(d, km, finished: finished));
    txn.update(ch.reference, {'status': 'done', 'winner': me, 'prize': prize,
      'finished_at': FieldValue.serverTimestamp(), 'validated_at': FieldValue.serverTimestamp()});
    if (prize > 0) {
      txn.update(user(me), {'coins': FieldValue.increment(prize), ...RunSaver.coinsTodayFields(ud, prize),
        'duel_prize_day': day, 'duel_prizes_today': paidToday + 1, 'last_duel_id': ch.id});
    }
  }

  static Future<bool> _beginValidation(String id, String me, double km, {required bool byDefault}) =>
      _db.runTransaction((txn) async {
    final ref = challenges.doc(id);
    final d = (await txn.get(ref)).data();
    if (d == null || d['status'] != 'active') return false;
    final target = (d['distance_km'] as num).toDouble();
    if (!byDefault && km < target) return false;
    txn.update(ref, {'status': 'validating', 'candidate': me, 'by_default': byDefault,
      'progress.$me': double.parse(km.toStringAsFixed(3)),
      'seen.$me': FieldValue.serverTimestamp(), 'validating_at': FieldValue.serverTimestamp()});
    return true;
  });

  static Future<bool> claimFinish(String id, String me, double km) => _beginValidation(id, me, km, byDefault: false);
  static Future<bool> claimWin(String id, String me, double km) => _beginValidation(id, me, km, byDefault: true);

  static Future<void> submitFinal(String id, String me, Map<String, dynamic> evidence, {bool verified = true, double? km}) async {
    if (DuelPolicy.invalidEvidence(evidence)) { await invalidate(id, me, evidence); return; }
    if (!verified) { await _closeChallenge(id, 'unverified'); return; }
    await _db.runTransaction((txn) async {
      final ref = challenges.doc(id);
      final d = (await txn.get(ref)).data();
      if (d == null || d['status'] != 'validating' || (d['finals'] as Map? ?? {}).containsKey(me)) return;
      txn.update(ref, {'finals.$me': {...evidence, 'invalid': false, 'for': d['validating_at']},
        if (km != null) 'progress.$me': double.parse(km.toStringAsFixed(3))});
    });
    await settle(id, me);
  }

  static Future<void> settle(String id, String me) => _db.runTransaction((txn) async {
    final snapshot = await txn.get(challenges.doc(id));
    final d = snapshot.data();
    if (d == null || d['status'] != 'validating' || d['candidate'] != me || DuelPolicy.expired(d, DateTime.now())) return;
    final finals = d['finals'] as Map? ?? {};
    if (!(d['participants'] as List).every((u) => finals[u] is Map &&
        finals[u]['invalid'] == false && finals[u]['for'] == d['validating_at'])) { return; }
    final km = ((d['progress'] as Map)[me] as num).toDouble();
    await _payWin(txn, snapshot, me, km, finished: d['by_default'] != true);
    // Keep room occupants busy through their post-run save/continue choice.
    // The coordinator releases each slot once that player leaves the room.
  });

  static Future<void> invalidate(String id, String me, Map<String, dynamic> evidence) async {
    if (!DuelPolicy.invalidEvidence(evidence)) throw const DuelUnavailable('Movement evidence is incomplete.');
    await _db.runTransaction((txn) async {
      final ref = challenges.doc(id);
      final d = (await txn.get(ref)).data();
      if (d == null || !['active', 'validating'].contains(d['status'])) return;
      final slots = await _slots(txn, d);
      txn.update(ref, {'status': 'invalid', 'invalidated_by': me, 'invalid_evidence': evidence,
        'invalid_reason': 'unrealistic_movement', 'finished_at': FieldValue.serverTimestamp()});
      _release(txn, id, slots);
    });
  }

  static Future<void> _closeChallenge(String id, String status) => _db.runTransaction((txn) async {
    final ref = challenges.doc(id);
    final d = (await txn.get(ref)).data();
    if (d == null || DuelPolicy.terminal.contains(d['status'])) return;
    final slots = d['protocol'] == DuelPolicy.version ? await _slots(txn, d) : <DocumentSnapshot<Map<String, dynamic>>>[];
    txn.update(ref, {'status': status, 'finished_at': FieldValue.serverTimestamp()});
    if (status == 'declined') {
      txn.set(cooldown(d['from'] as String, d['to'] as String), {'challenge_id': id, 'declined_at': FieldValue.serverTimestamp()});
    }
    _release(txn, id, slots);
  });

  static Future<void> expireChallenge(String id) => _db.runTransaction((txn) async {
    final ref = challenges.doc(id);
    final d = (await txn.get(ref)).data();
    if (d == null || DuelPolicy.terminal.contains(d['status'])) return;
    final slots = d['protocol'] == DuelPolicy.version ? await _slots(txn, d) : <DocumentSnapshot<Map<String, dynamic>>>[];
    final staleActivity = d['status'] == 'active' && slots.any((s) => !_leased(s.data()));
    if (d['protocol'] == DuelPolicy.version && !DuelPolicy.expired(d, DateTime.now()) && !staleActivity) return;
    final status = d['status'] == 'validating' || staleActivity ? 'unverified' : 'expired';
    txn.update(ref, {'status': status, 'finished_at': FieldValue.serverTimestamp()});
    _release(txn, id, slots);
  });

  /// Explicit forfeit still requires both final movement reports before payment.
  static Future<void> leave(String id, String me) => _db.runTransaction((txn) async {
    final ref = challenges.doc(id);
    final d = (await txn.get(ref)).data();
    if (d == null || DuelPolicy.terminal.contains(d['status'])) return;
    if (d['status'] == 'active') {
      final other = (d['participants'] as List).firstWhere((u) => u != me);
      txn.update(ref, {'status': 'validating', 'candidate': other, 'by_default': true,
        'forfeit_by': me, 'validating_at': FieldValue.serverTimestamp()});
    } else if (d['status'] != 'validating') {
      final slots = await _slots(txn, d);
      txn.update(ref, {'status': 'cancelled', 'finished_at': FieldValue.serverTimestamp()});
      _release(txn, id, slots);
    }
  });

  /// Week / month km for the leaderboards. [at] = when the run happened: a
  /// run that reaches the server late (for example run on Sunday, synced on
  /// Monday) is only added to the week and month it was really run in, and
  /// never to an older period that is already over.
  static Map<String, dynamic> weekFields(Map<String, dynamic> userData, double km,
      {DateTime? at}) {
    final now = DateTime.now();
    final when = at ?? now;
    final out = <String, dynamic>{'last_run_at': FieldValue.serverTimestamp()};
    final key = Weekly.key(when);
    if (key == Weekly.key(now)) {
      final same = userData['week_key'] == key;
      final prev = same ? ((userData['week_km'] as num?)?.toDouble() ?? 0) : 0.0;
      out['week_key'] = key;
      out['week_km'] = double.parse((prev + km).toStringAsFixed(3));
    }
    // monthly leaderboard
    String month(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
    final mKey = month(when);
    if (mKey == month(now)) {
      final mSame = userData['month_key'] == mKey;
      final mPrev = mSame ? ((userData['month_km'] as num?)?.toDouble() ?? 0) : 0.0;
      out['month_key'] = mKey;
      out['month_km'] = double.parse((mPrev + km).toStringAsFixed(3));
    }
    return out;
  }

  // ───────────────────────── chat ─────────────────────────

  static String chatId(String a, String b) =>
      a.compareTo(b) < 0 ? '${a}_$b' : '${b}_$a';

  static const int maxMessage = 300;

  static Future<void> sendMessage({
    required String me,
    required String other,
    required String text,
  }) async {
    var t = text.trim();
    if (t.isEmpty) return;
    if (t.length > maxMessage) t = t.substring(0, maxMessage);
    final ref = chats.doc(chatId(me, other));
    final batch = _db.batch();
    batch.set(ref.collection('messages').doc(),
        {'from': me, 'text': t, 'ts': FieldValue.serverTimestamp()});
    batch.set(
      ref,
      {
        'members': [me, other],
        'last_text': t.length > 60 ? '${t.substring(0, 60)}…' : t,
        'last_from': me,
        'last_at': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    await batch.commit();
  }

  static Future<void> markRead(String me, String other) async {
    try {
      await chats.doc(chatId(me, other)).set({
        'members': [me, other],
        'read': {me: FieldValue.serverTimestamp()},
      }, SetOptions(merge: true));
    } catch (_) {}
  }
}

class DuelUnavailable implements Exception {
  final String message;
  const DuelUnavailable(this.message);
  @override
  String toString() => message;
}
