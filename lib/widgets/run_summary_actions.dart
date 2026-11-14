import 'dart:async';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../services/run_summary_export.dart';
import '../models/run_summary_export.dart';
import 'block_inputs.dart';
import 'block_ui.dart';

class RunSummaryActions extends StatefulWidget {
  final String? ownerUid;
  final String? runId;
  final ValueChanged<RunSummaryExport>? onConfirmed;
  const RunSummaryActions({super.key, this.ownerUid, this.runId, this.onConfirmed});

  @override
  State<RunSummaryActions> createState() => _RunSummaryActionsState();
}

class _RunSummaryActionsState extends State<RunSummaryActions> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subscription;
  Uint8List? _png;
  String _name = 'hakbanghero.png';
  String? _error;
  bool _preparing = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    final uid = widget.ownerUid, id = widget.runId;
    if (uid == null || id == null) return;
    _subscription?.cancel();
    _subscription = FirebaseFirestore.instance.collection('users').doc(uid)
        .collection('activities').doc(id).snapshots(includeMetadataChanges: true).listen((doc) async {
      if (!mounted || _png != null || _preparing || !doc.exists ||
          doc.metadata.hasPendingWrites || doc.metadata.isFromCache) {
        return;
      }
      setState(() { _preparing = true; _error = null; });
      try {
        final summary = RunSummaryExportService.confirmed(doc);
        widget.onConfirmed?.call(summary);
        final png = await RunSummaryExportService.render(summary);
        if (mounted) setState(() { _png = png; _name = summary.fileName; });
      } catch (e) {
        if (mounted) setState(() => _error = 'Image unavailable: ${e.toString().replaceFirst('Bad state: ', '')}');
      } finally {
        if (mounted) setState(() => _preparing = false);
      }
    }, onError: (Object e) {
      if (mounted) setState(() => _error = 'Could not load the saved run. Tap RETRY.');
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _export(bool share) async {
    final png = _png;
    if (png == null || _busy) return;
    if (FirebaseAuth.instance.currentUser?.uid != widget.ownerUid) {
      blockSnack(context, 'Sign in to the account that recorded this run.');
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null ? const Rect.fromLTWH(0, 0, 1, 1) : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _busy = true);
    try {
      final result = await (share
          ? RunSummaryExportService.share(png, _name, origin)
          : RunSummaryExportService.save(png, _name));
      if (mounted) blockSnack(context, result.message);
    } catch (_) {
      if (mounted) {
        blockSnack(context, share
          ? 'Sharing is unavailable or failed. Try Save Image instead.'
          : 'Could not export the image. Try Share or another browser.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _button(String label, IconData icon, VoidCallback? onTap) => PressBlock(
    color: Rb.blue, edge: Rb.blueEdge, depth: 4, radius: 12,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14), onTap: onTap,
    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, color: Colors.white, size: 19), const SizedBox(width: 6),
      Flexible(child: Text(label, textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900))),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final ready = _png != null && !_busy;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(child: _button('Share', Icons.share, ready ? () => _export(true) : null)),
        const SizedBox(width: 8),
        Expanded(child: _button('Save Image', Icons.download, ready ? () => _export(false) : null)),
      ]),
      if (!ready && !_busy) ...[
        const SizedBox(height: 4),
        Text(_error ?? (_preparing ? 'Preparing image...' :
          widget.runId == null ? 'Only saved runs can be exported.' : 'Share available after this run syncs.'),
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Colors.black)),
        if (_error != null) TextButton(onPressed: () {
          setState(() => _error = null);
          _listen();
        }, child: const Text('RETRY')),
      ],
    ]);
  }
}
