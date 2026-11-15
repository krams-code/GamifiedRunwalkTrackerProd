import 'dart:async';
import 'package:flutter/material.dart';
import '../models/duel_policy.dart';
import '../services/duel_coordinator.dart';
import '../services/friends_service.dart';
import '../screens/friends/duel_room_screen.dart';
import 'block_ui.dart';
import 'game_notice.dart';

final duelNavigatorKey = GlobalKey<NavigatorState>();
final duelNavigationObserver = DuelNavigationObserver();

class DuelNavigationObserver extends NavigatorObserver {
  final List<Route<dynamic>> routes = [];
  bool get modalOpen => routes.isNotEmpty && routes.last is PopupRoute;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => routes.add(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => routes.remove(route);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => routes.remove(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    routes.remove(oldRoute);
    if (newRoute != null) routes.add(newRoute);
  }
}

/// A single foreground modal across the root navigator, including detail pages.
class DuelInvitationHost extends StatefulWidget {
  final Widget child;
  const DuelInvitationHost({super.key, required this.child});
  @override
  State<DuelInvitationHost> createState() => _DuelInvitationHostState();
}

class _DuelInvitationHostState extends State<DuelInvitationHost> {
  final _coordinator = DuelCoordinator.I;
  Route<bool>? _invitation;
  Route<void>? _room;
  String? _invitationId, _account;
  final Set<String> _shown = {};
  bool _handling = false;
  @override
  void initState() {
    super.initState();
    _coordinator.addListener(_changed);
    _coordinator.openRoom = _enterRoom;
  }
  @override
  void dispose() {
    _coordinator.removeListener(_changed);
    _coordinator.openRoom = null;
    super.dispose();
  }

  void _changed() {
    if (mounted) WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _handle(); });
  }

  void _dismissInvitation() {
    final route = _invitation;
    _invitation = null; _invitationId = null;
    if (route?.isActive ?? false) duelNavigatorKey.currentState?.removeRoute(route!);
  }

  Future<void> _enterRoom(String id) async {
    if (_coordinator.roomId != null || _coordinator.soloBusy || !_coordinator.foreground || !_coordinator.ownsSession) return;
    final nav = duelNavigatorKey.currentState;
    if (nav == null || duelNavigationObserver.modalOpen) return;
    _coordinator.roomId = id;
    final route = MaterialPageRoute<void>(builder: (_) => DuelRoomScreen(challengeId: id));
    _room = route;
    try { await nav.push(route); } finally {
      if (_room == route) _room = null;
      if (_coordinator.roomId == id) _coordinator.roomId = null;
      await _coordinator.releaseRoom(id).catchError((_) {});
    }
  }

  Future<void> _handle() async {
    if (_account != _coordinator.uid) {
      _account = _coordinator.uid; _shown.clear(); _dismissInvitation();
      if (_room?.isActive ?? false) duelNavigatorKey.currentState?.removeRoute(_room!);
      _room = null;
    }
    final id = _coordinator.challengeId, d = _coordinator.challenge, me = _coordinator.uid;
    if (_invitation != null && (id != _invitationId || d?['status'] != 'pending' ||
        !_coordinator.foreground || _coordinator.soloBusy || (d != null && DuelPolicy.expired(d, DateTime.now())))) {
      _dismissInvitation();
    }
    if (_handling || me == null || id == null || d == null || !_coordinator.foreground ||
        _coordinator.soloBusy || _coordinator.roomId != null || duelNavigationObserver.modalOpen) { return; }
    if (d['protocol'] != DuelPolicy.version) return;
    if (['lobby', 'countdown', 'active', 'validating'].contains(d['status']) && _coordinator.ownsSession) {
      await _enterRoom(id);
      return;
    }
    final context = duelNavigatorKey.currentState?.overlay?.context;
    if (context == null || !context.mounted) return;
    _handling = true;
    try {
      if (d['status'] == 'pending' && d['to'] == me && _invitation == null &&
          !DuelPolicy.expired(d, DateTime.now()) && _coordinator.ownsSession) {
        if (!await FriendsService.acknowledgeChallenge(id, me, _coordinator.session)) return;
        if (!context.mounted || _coordinator.soloBusy || !_coordinator.foreground ||
            _coordinator.challenge?['status'] != 'pending') { return; }
        final route = DialogRoute<bool>(context: context, barrierDismissible: false,
          builder: (_) => DuelInvitationDialog(duel: d, onAccept: () =>
            FriendsService.acceptChallenge(id, me, _coordinator.session),
            onDecline: () => FriendsService.declineChallenge(id)));
        _invitation = route; _invitationId = id;
        final accepted = await duelNavigatorKey.currentState!.push(route);
        if (_invitation == route) { _invitation = null; _invitationId = null; }
        if (accepted == true) await _enterRoom(id);
      } else if (DuelPolicy.terminal.contains(d['status']) &&
          _coordinator.slot?['outcome_seen'] != id && _shown.add(id)) {
        if (['declined', 'busy'].contains(d['status']) && d['to'] == me) {
          await FriendsService.activity(me).update({'outcome_seen': id});
          return;
        }
        final message = switch (d['status']) {
          'invalid' => DuelPolicy.dismissedMessage,
          'declined' => d['from'] == me ? DuelPolicy.declinedMessage : 'You declined this duel invitation.',
          'busy' => DuelPolicy.busyMessage,
          'unverified' => 'This duel could not be verified and ended without rewards.',
          'expired' => 'This duel invitation or room expired. No duel rewards were awarded.',
          'done' => 'This duel has finished. Check DUELS for the confirmed result.',
          _ => 'This duel was cancelled.',
        };
        await showGameAlert(context, title: 'DUEL UPDATE', message: message);
        if (_coordinator.uid == me) {
          await FriendsService.activity(me).update({'outcome_seen': id}).catchError((_) {});
        }
      }
    } catch (_) {
      // The invitation remains unresolved and can be retried while valid.
    } finally {
      _handling = false;
    }
  }
  @override
  Widget build(BuildContext context) => widget.child;
}

class DuelInvitationDialog extends StatefulWidget {
  final Map<String, dynamic> duel;
  final Future<void> Function() onAccept, onDecline;
  const DuelInvitationDialog({super.key, required this.duel, required this.onAccept, required this.onDecline});
  @override
  State<DuelInvitationDialog> createState() => _DuelInvitationDialogState();
}

class _DuelInvitationDialogState extends State<DuelInvitationDialog> {
  bool _busy = false;
  String? _error;
  Future<void> _resolve(bool accept) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await (accept ? widget.onAccept() : widget.onDecline());
      if (mounted) Navigator.of(context).pop(accept);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = FriendsService.duelError(e); });
    }
  }
  @override
  Widget build(BuildContext context) => PopScope(canPop: false, child: Dialog(
    backgroundColor: Colors.transparent,
    child: Block(color: Rb.slate, edge: Colors.black, depth: 8, radius: 22,
      padding: const EdgeInsets.all(18), child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, children: [
          const BlockText('DUEL INVITATION', size: 20, stroke: 4, color: Rb.gold),
          const SizedBox(height: 10),
          BlockText('${widget.duel['from_name'] ?? 'Hero'} challenges you!', size: 16, stroke: 3.5, align: TextAlign.center),
          const SizedBox(height: 6),
          BlockText('${widget.duel['distance_km']} km live race • Winner: ${widget.duel['reward']} coins',
            size: 12, stroke: 3, color: Rb.neon, align: TextAlign.center),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: BlockText(_error!, size: 12, stroke: 3, align: TextAlign.center)),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, children: [
            PressBlock(color: Rb.green, edge: Rb.greenEdge, depth: 4,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              onTap: _busy ? null : () => _resolve(true), child: const BlockText('ACCEPT', size: 14, stroke: 3.5)),
            PressBlock(color: Rb.red, edge: Rb.redEdge, depth: 4,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              onTap: _busy ? null : () => _resolve(false), child: const BlockText('DECLINE', size: 14, stroke: 3.5)),
          ]),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 8),
            child: BlockText('Updating invitation...', size: 12, stroke: 3, align: TextAlign.center)),
        ],
      ))),
  ));
}
