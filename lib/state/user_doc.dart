import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/character_profile.dart' show isFemaleGender;
import '../models/hero_roster.dart' show HeroLook;

/// ONE Firestore listener on `users/{uid}` for the whole app.
///
/// Before, about eight widgets each opened their own `.snapshots()` and
/// several created it inside `build()`, so every rebuild re-subscribed and
/// flashed a spinner. Now they all share this stream and start from the last
/// known value (`initialData`), so tab switches show data instantly.
///
///   StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
///     stream: UserDoc.instance.stream,
///     initialData: UserDoc.instance.snapshotFor(uid),
///     builder: ...
class UserDoc {
  UserDoc._();
  static final UserDoc instance = UserDoc._();

  final StreamController<DocumentSnapshot<Map<String, dynamic>>> _ctrl =
      StreamController<DocumentSnapshot<Map<String, dynamic>>>.broadcast();

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  String? _uid;
  DocumentSnapshot<Map<String, dynamic>>? _last;

  void _ensure() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == _uid && (_sub != null || uid == null)) return;
    _sub?.cancel();
    _sub = null;
    _last = null;
    _uid = uid;
    if (uid == null) {
      HeroLook.meGirl = false;
      return;
    }
    _sub = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen(
      (s) {
        _last = s;
        // girl / boy SPROUT art for this player, before anyone rebuilds
        HeroLook.meGirl = isFemaleGender(s.data()?['gender'] as String?);
        _ctrl.add(s);
      },
      onError: _ctrl.addError,
    );
  }

  /// Stable stream (same object every call, so StreamBuilder never resubscribes).
  ///
  /// Every new listener gets the LATEST snapshot at once, then live updates.
  /// (A plain broadcast stream only delivers future events: a screen that
  /// opened just after the profile arrived waited forever on the loading
  /// runner until the player switched tabs and came back.)
  Stream<DocumentSnapshot<Map<String, dynamic>>> get stream {
    _ensure();
    return _replay;
  }

  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _replay =
      _ReplayLatest(this);

  /// Last value we saw for [uid] (null until the first snapshot arrives).
  DocumentSnapshot<Map<String, dynamic>>? snapshotFor(String? uid) {
    _ensure();
    return (uid != null && uid == _uid) ? _last : null;
  }
}

/// Broadcast stream that starts every listener with the last known value.
class _ReplayLatest extends Stream<DocumentSnapshot<Map<String, dynamic>>> {
  final UserDoc _owner;
  _ReplayLatest(this._owner);

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> listen(
    void Function(DocumentSnapshot<Map<String, dynamic>> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final out = StreamController<DocumentSnapshot<Map<String, dynamic>>>();
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? live;
    out.onListen = () {
      final last = _owner._last;
      if (last != null) out.add(last);
      live = _owner._ctrl.stream.listen(out.add, onError: out.addError);
    };
    out.onCancel = () => live?.cancel();
    return out.stream.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }
}
