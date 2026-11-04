import 'package:flutter/material.dart';

import '../services/sound.dart';
import '../services/presence.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'block_ui.dart';
import 'delete_account_dialog.dart';
import 'tester_panel.dart';
import '../services/tester_mode.dart';

/// ⚙ SETTINGS pop-up: music, sound effects, vibration.
/// Open it with [showSettingsSheet]. Everything saves on the phone at once.
Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context) {
    final s = Sound.I;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: Block(
          color: const Color(0xFF9A9EA3),
          edge: Colors.black,
          depth: 8,
          radius: 22,
          padding: const EdgeInsets.all(14),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: BlockText('⚙ SETTINGS', size: 22, stroke: 5),
                ),
                const SizedBox(height: 12),
                _SliderRow(
                  label: '🎵 MUSIC',
                  on: s.musicOn,
                  volume: s.musicVolume,
                  onToggle: s.setMusic,
                  onVolume: (v, _) => s.setMusicVolume(v),
                ),
                const SizedBox(height: 10),
                _SliderRow(
                  label: '🔊 SOUND EFFECTS',
                  on: s.sfxOn,
                  volume: s.sfxVolume,
                  onToggle: s.setSfx,
                  onVolume: (v, done) => s.setSfxVolume(v, preview: done),
                ),
                const SizedBox(height: 10),
                Block(
                  color: Rb.panel,
                  edge: Rb.panelEdge,
                  depth: 5,
                  radius: 14,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    const Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: BlockText('📳 VIBRATION', size: 15, stroke: 3.5),
                        ),
                      ),
                    ),
                    _Switch(on: s.vibrateOn, onToggle: s.setVibrate),
                  ]),
                ),
                const SizedBox(height: 10),
                Block(
                  color: Rb.panel,
                  edge: Rb.panelEdge,
                  depth: 5,
                  radius: 14,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    const Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: BlockText('🟢 FRIEND ONLINE ALERTS', size: 15, stroke: 3.5),
                        ),
                      ),
                    ),
                    _Switch(
                        on: Presence.I.friendAlerts,
                        onToggle: Presence.I.setFriendAlerts),
                  ]),
                ),
                const SizedBox(height: 14),
                PressBlock(
                  color: Rb.blue,
                  edge: Rb.blueEdge,
                  depth: 7,
                  radius: 14,
                  silent: true, // closing the sheet plays the sound
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  onTap: () => Navigator.of(context).maybePop(),
                  child: const SizedBox(
                    width: double.infinity,
                    child: Center(child: BlockText('DONE', size: 17, stroke: 4)),
                  ),
                ),
                if (FirebaseAuth.instance.currentUser != null) ...[
                  // only accounts listed in Firestore "testers" see this
                  _TesterEntry(uid: FirebaseAuth.instance.currentUser!.uid),
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: () async {
                      final nav = Navigator.of(context);
                      await nav.maybePop(); // close Settings first
                      if (nav.context.mounted) {
                        await showDeleteAccountDialog(nav.context);
                      }
                    },
                    child: const Text(
                      'Delete my account',
                      style: TextStyle(
                        color: Color(0xFF7A1C20),
                        fontWeight: FontWeight.w800,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "TESTER TOOLS" button, shown only to tester accounts.
class _TesterEntry extends StatefulWidget {
  final String uid;
  const _TesterEntry({required this.uid});

  @override
  State<_TesterEntry> createState() => _TesterEntryState();
}

class _TesterEntryState extends State<_TesterEntry> {
  late final Future<bool> _isTester = TesterMode.check(widget.uid);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _isTester,
      builder: (context, snap) {
        if (snap.data != true) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: PressBlock(
            color: const Color(0xFF6B4FD8),
            edge: const Color(0xFF2A1B66),
            depth: 6,
            radius: 14,
            padding: const EdgeInsets.symmetric(vertical: 12),
            onTap: () async {
              final nav = Navigator.of(context);
              await nav.maybePop(); // close Settings first
              if (nav.context.mounted) await showTesterPanel(nav.context);
            },
            child: const SizedBox(
              width: double.infinity,
              child: Center(child: BlockText('TESTER TOOLS', size: 16, stroke: 4)),
            ),
          ),
        );
      },
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final ValueNotifier<bool> on;
  final ValueNotifier<double> volume;
  final Future<void> Function(bool) onToggle;
  final void Function(double value, bool finished) onVolume;

  const _SliderRow({
    required this.label,
    required this.on,
    required this.volume,
    required this.onToggle,
    required this.onVolume,
  });

  @override
  Widget build(BuildContext context) {
    return Block(
      color: Rb.panel,
      edge: Rb.panelEdge,
      depth: 5,
      radius: 14,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: BlockText(label, size: 15, stroke: 3.5),
              ),
            ),
          ),
          _Switch(on: on, onToggle: onToggle),
        ]),
        ValueListenableBuilder<bool>(
          valueListenable: on,
          builder: (_, isOn, __) => ValueListenableBuilder<double>(
            valueListenable: volume,
            builder: (_, v, __) => SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: Rb.green,
                inactiveTrackColor: Rb.track,
                thumbColor: Rb.neon,
                overlayColor: Rb.green.withValues(alpha: 0.2),
                trackHeight: 8,
              ),
              child: Slider(
                value: v,
                onChanged: isOn ? (x) => onVolume(x, false) : null,
                onChangeEnd: isOn ? (x) => onVolume(x, true) : null,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Switch extends StatelessWidget {
  final ValueNotifier<bool> on;
  final Future<void> Function(bool) onToggle;
  const _Switch({required this.on, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: on,
      builder: (_, isOn, __) => PressBlock(
        color: isOn ? Rb.green : Rb.red,
        edge: isOn ? Rb.greenEdge : Rb.redEdge,
        depth: 4,
        radius: 10,
        silent: true, // the setting plays its own confirmation
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        onTap: () => onToggle(!isOn),
        child: BlockText(isOn ? 'ON' : 'OFF', size: 14, stroke: 3.5),
      ),
    );
  }
}
