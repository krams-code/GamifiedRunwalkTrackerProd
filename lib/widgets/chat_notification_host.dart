import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../services/chat_inbox.dart';
import '../services/duel_coordinator.dart';
import '../screens/friends/friends_screen.dart';
import 'block_ui.dart';
import 'duel_invitation_host.dart'
    show duelNavigatorKey, duelNavigationObserver;

class ChatNotificationHost extends StatefulWidget {
  final Widget child;
  const ChatNotificationHost({super.key, required this.child});
  @override
  State<ChatNotificationHost> createState() => _ChatNotificationHostState();
}

class _ChatNotificationHostState extends State<ChatNotificationHost>
    with WidgetsBindingObserver {
  final _inbox = ChatInbox.I;
  StreamSubscription<User?>? _auth;
  Timer? _timer;
  int _seen = 0;
  String? _chat;
  double _drag = 0;
  bool get _suppressed {
    final duel = DuelCoordinator.I;
    return !_inbox.foreground ||
        duel.soloBusy ||
        (duel.roomId != null &&
            [
              'countdown',
              'active',
              'validating',
            ].contains(duel.challenge?['status']));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inbox.foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _inbox.addListener(_changed);
    DuelCoordinator.I.addListener(_changed);
    _auth = FirebaseAuth.instance.authStateChanges().listen(
      (u) => _inbox.start(u?.uid),
    );
  }

  void _changed() {
    if (!mounted) return;
    // Notifications can arrive while a screen is building or marking chat read.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final newArrival = _seen != _inbox.arrival;
      _seen = _inbox.arrival;
      if (_suppressed ||
          (_chat != null &&
              (_inbox.countFor(_chat!) == 0 || _inbox.openChat == _chat))) {
        _dismiss();
        return;
      }
      if (newArrival &&
          !duelNavigationObserver.modalOpen &&
          _inbox.arrivalChat != null) {
        _timer?.cancel();
        setState(() {
          _chat = _inbox.arrivalChat;
          _drag = 0;
        });
        _timer = Timer(const Duration(seconds: 5), _dismiss);
      } else if (_chat != null) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _dismiss() {
    _timer?.cancel();
    if (mounted && _chat != null) setState(() => _chat = null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inbox.foreground = state == AppLifecycleState.resumed;
    if (!_inbox.foreground) _dismiss();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _auth?.cancel();
    _inbox.removeListener(_changed);
    DuelCoordinator.I.removeListener(_changed);
    _inbox.start(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = _chat == null ? 0 : _inbox.countFor(_chat!);
    return Stack(
      children: [
        widget.child,
        Positioned(
          top: 0,
          left: 12,
          right: 12,
          child: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  transitionBuilder: (child, animation) => SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(0, -1.3),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: animation,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: _chat == null || count == 0
                      ? const SizedBox.shrink()
                      : Material(
                          key: ValueKey(_chat),
                          color: Colors.transparent,
                          child: GestureDetector(
                            onVerticalDragStart: (_) => _drag = 0,
                            onVerticalDragUpdate: (d) {
                              _drag += d.delta.dy;
                              if (_drag < -14) _dismiss();
                            },
                            onVerticalDragEnd: (d) {
                              if ((d.primaryVelocity ?? 0) < -100) _dismiss();
                            },
                            onTap: () {
                              _dismiss();
                              if (!_suppressed &&
                                  !duelNavigationObserver.modalOpen) {
                                duelNavigatorKey.currentState?.push(
                                  MaterialPageRoute(
                                    builder: (_) => const FriendsScreen(),
                                  ),
                                );
                              }
                            },
                            child: Block(
                              color: Rb.blue,
                              edge: Rb.blueEdge,
                              depth: 5,
                              radius: 16,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 13,
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.chat_bubble_rounded,
                                    color: Colors.white,
                                    size: 27,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const BlockText(
                                          'CHAT',
                                          size: 12,
                                          stroke: 3,
                                          color: Rb.gold,
                                        ),
                                        const SizedBox(height: 4),
                                        BlockText(
                                          '$count unread ${count == 1 ? 'message' : 'messages'}',
                                          size: 16,
                                          stroke: 3.5,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(
                                    Icons.keyboard_arrow_up_rounded,
                                    color: Colors.white70,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shared unread dot for every entry into Friends.
class ChatUnreadDot extends StatelessWidget {
  final Widget child;
  const ChatUnreadDot({super.key, required this.child});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: ChatInbox.I,
    builder: (context, _) => Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (ChatInbox.I.total > 0)
          Positioned(
            top: -4,
            right: -4,
            child: Semantics(
              label: '${ChatInbox.I.total} unread messages',
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Rb.red,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black, width: 2),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
