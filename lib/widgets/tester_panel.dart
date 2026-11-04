import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/run_mode.dart';
import '../services/run_saver.dart';
import '../services/tester_mode.dart';
import '../utils/player_stats.dart';
import 'block_ui.dart';
import 'game_notice.dart';

/// TESTER TOOLS pop-up (only shown to accounts listed in Firestore `testers`).
Future<void> showTesterPanel(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _TesterPanel(),
  );
}

class _TesterPanel extends StatefulWidget {
  const _TesterPanel();

  @override
  State<_TesterPanel> createState() => _TesterPanelState();
}

class _TesterPanelState extends State<_TesterPanel> {
  final String? _uid = FirebaseAuth.instance.currentUser?.uid;
  bool _busy = false;

  /// Runs [job], then shows [done] (or why it failed).
  ///
  /// [instant] tools are plain saves: the change shows on screen at once and
  /// the server is not waited for. If it refuses, Firestore undoes the
  /// change and the reason is shown.
  Future<void> _run(String done, Future<void> Function(String uid) job,
      {bool instant = true}) async {
    final uid = _uid;
    if (uid == null || _busy) return;
    if (instant) {
      job(uid).catchError((Object e) {
        debugPrint('tester tool refused: $e');
        if (mounted) {
          showGameAlert(context,
              title: 'NOT DONE',
              message: '${RunSaver.describe(e)}\n\nIs this account in the '
                  'Firestore "testers" list, and are the newest rules deployed?');
        }
      });
      showGameToast(context, done, kind: NoticeKind.success);
      return;
    }
    setState(() => _busy = true);
    try {
      await job(uid).timeout(RunSaver.timeout);
      if (mounted) showGameToast(context, done, kind: NoticeKind.success);
    } catch (e) {
      debugPrint('tester tool failed: $e');
      if (mounted) {
        showGameAlert(context,
            title: 'NOT DONE',
            message: '${RunSaver.describe(e)}\n\nIs this account in the '
                'Firestore "testers" list, and are the newest rules deployed?');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Block(
          color: const Color(0xFF7A2A2A),
          edge: const Color(0xFF2E0E0E),
          depth: 7,
          radius: 20,
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            BlockText(title, size: 20, stroke: 5, color: const Color(0xFFFFD166)),
            const SizedBox(height: 8),
            BlockText(message, size: 12.5, stroke: 3, align: TextAlign.center),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: PressBlock(
                  color: Rb.slot,
                  edge: Rb.slateEdge,
                  depth: 5,
                  radius: 12,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  onTap: () => Navigator.of(ctx).pop(false),
                  child: const Center(child: BlockText('CANCEL', size: 14, stroke: 3.5)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PressBlock(
                  color: Rb.red,
                  edge: Rb.redEdge,
                  depth: 5,
                  radius: 12,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  onTap: () => Navigator.of(ctx).pop(true),
                  child: const Center(child: BlockText('YES', size: 14, stroke: 3.5)),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
    return ok == true;
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: BlockText(title, size: 13, stroke: 3, color: const Color(0xFFFFD166)),
        ),
      );

  Widget _button(String label, VoidCallback onTap,
      {Color color = Rb.blue, Color edge = Rb.blueEdge}) {
    return PressBlock(
      color: _busy ? Rb.slot : color,
      edge: _busy ? Rb.slateEdge : edge,
      depth: 5,
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      onTap: _busy ? null : onTap,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: BlockText(label, size: 13, stroke: 3),
        ),
      ),
    );
  }

  Widget _pair(Widget a, Widget b) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Expanded(child: a),
          const SizedBox(width: 8),
          Expanded(child: b),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    if (uid == null) return const SizedBox.shrink();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: Block(
          color: const Color(0xFF3D2E6B),
          edge: const Color(0xFF15102A),
          depth: 8,
          radius: 22,
          padding: const EdgeInsets.all(14),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.82),
            child: SingleChildScrollView(
              child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(uid)
                    .snapshots(),
                builder: (context, snap) {
                  final d = snap.data?.data() ?? const <String, dynamic>{};
                  final xp = (d['xp'] as num?)?.toInt() ?? 0;
                  final lv = LevelProgress.fromXp(xp).level;
                  final coins = (d['coins'] as num?)?.toInt() ?? 0;
                  final km = (d['total_km'] as num?)?.toDouble() ?? 0;
                  final stars = RunMode.totalStars(d['stage_records']);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: BlockText('TESTER TOOLS', size: 22, stroke: 5),
                      ),
                      const SizedBox(height: 4),
                      const BlockText(
                        'Test account only. Changes are real on this account '
                        'and it is hidden from the leaderboards.',
                        size: 11,
                        stroke: 2.5,
                        align: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      Block(
                        color: Rb.panel,
                        edge: Rb.panelEdge,
                        depth: 4,
                        radius: 12,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: BlockText(
                            'LV $lv  •  $xp XP  •  $coins COINS\n'
                            '${km.toStringAsFixed(1)} KM  •  $stars/${RunMode.maxStars} RANK STARS',
                            size: 12.5,
                            stroke: 3,
                            align: TextAlign.center,
                          ),
                        ),
                      ),
                      _section('RUN MODES, HEROES & ITEMS'),
                      _pair(
                        _button('UNLOCK ALL MODES', () {
                          _run('Every rank and trial is cleared. All modes, '
                              'rank heroes and rank items are open.',
                              TesterMode.unlockAllModes);
                        }, color: Rb.green, edge: Rb.greenEdge),
                        _button('LOCK ALL MODES', () async {
                          if (await _confirm('LOCK ALL?',
                              'Clears every rank and trial record, so only '
                              'BEGINNER is open again.')) {
                            _run('All modes are locked again.',
                                TesterMode.lockAllModes);
                          }
                        }, color: Rb.red, edge: Rb.redEdge),
                      ),
                      _section('LEVEL, COINS & DISTANCE'),
                      _pair(
                        _button('+1 LEVEL', () {
                          _run('Level up!', (u) => TesterMode.addLevels(u, xp, 1));
                        }),
                        _button('+5 LEVELS', () {
                          _run('Five levels up!',
                              (u) => TesterMode.addLevels(u, xp, 5));
                        }),
                      ),
                      _pair(
                        _button('+5,000 COINS', () {
                          _run('+5,000 coins added.',
                              (u) => TesterMode.addCoins(u, 5000));
                        }, color: Rb.gold, edge: Rb.goldEdge),
                        _button('+25 TOTAL KM', () {
                          _run('+25 lifetime km added.',
                              (u) => TesterMode.addTotalKm(u, 25));
                        }),
                      ),
                      _section('RUNS, STREAK & WEEKLY GOAL'),
                      _pair(
                        _button('ADD 3 KM RUN', () {
                          _run('A 3 km test run was saved (XP, coins, quests '
                              'and weekly goal count it).', (u) async {
                            await TesterMode.addTestRun(u, km: 3, minutes: 20);
                          }, instant: false);
                        }, color: Rb.green, edge: Rb.greenEdge),
                        _button('ADD 6 KM RUN', () {
                          _run('A 6 km test run was saved.', (u) async {
                            await TesterMode.addTestRun(u, km: 6, minutes: 40);
                          }, instant: false);
                        }, color: Rb.green, edge: Rb.greenEdge),
                      ),
                      _pair(
                        _button('ADD 7-DAY STREAK', () {
                          _run('Runs added on the last 7 days. Run today (or '
                              'ADD 3 KM RUN) and open the shop for the '
                              'streak rewards.',
                              (u) => TesterMode.addStreakDays(u, 7));
                        }),
                        _button('ADD 30-DAY STREAK', () {
                          _run('Runs added on the last 30 days.',
                              (u) => TesterMode.addStreakDays(u, 30));
                        }),
                      ),
                      _section('WAIT TIMERS'),
                      _pair(
                        _button('RESET ALL TIMERS', () {
                          _run('Streak, weekly goal, daily quests and the '
                              'weekly check-in are open again.',
                              TesterMode.resetTimers);
                        }, color: Rb.gold, edge: Rb.goldEdge),
                        _button('START OVER', () async {
                          if (await _confirm('START OVER?',
                              'Level 1, 0 km, 100 coins and all modes locked. '
                              'Bought items, your hero and run history stay.')) {
                            _run('Progress reset to a new player.',
                                TesterMode.resetProgress);
                          }
                        }, color: Rb.red, edge: Rb.redEdge),
                      ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: uid));
                          showGameToast(context, 'Player ID copied.',
                              kind: NoticeKind.success);
                        },
                        child: BlockText('PLAYER ID: $uid (tap to copy)',
                            size: 10, stroke: 2.2, align: TextAlign.center),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: _button('DONE', () => Navigator.of(context).maybePop()),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
