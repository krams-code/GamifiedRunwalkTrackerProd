import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../services/legal_consent.dart';
import '../../widgets/block_ui.dart';
import '../../widgets/block_inputs.dart';
import '../../widgets/legal_consent_controls.dart';

class LegalConsentScreen extends StatefulWidget {
  final VoidCallback onAccepted;
  final bool canGoBack;
  const LegalConsentScreen({super.key, required this.onAccepted, this.canGoBack = false});

  @override
  State<LegalConsentScreen> createState() => _LegalConsentScreenState();
}

class _LegalConsentScreenState extends State<LegalConsentScreen> {
  bool _terms = false;
  bool _privacy = false;
  bool _submitted = false;
  bool _saving = false;

  Future<void> _continue() async {
    if (_saving) return;
    setState(() => _submitted = true);
    final error = LegalConsent.validationError(_terms, _privacy);
    if (error != null) {
      blockSnack(context, error);
      return;
    }
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      blockSnack(context, 'Please sign in again.');
      return;
    }
    setState(() => _saving = true);
    try {
      await LegalConsent.save(uid, terms: _terms, privacy: _privacy);
      if (mounted) widget.onAccepted();
    } catch (_) {
      if (mounted) blockSnack(context, 'Could not save your acceptance. Check your connection and retry.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: widget.canGoBack && !_saving,
    child: Scaffold(
      backgroundColor: Rb.bg,
      body: SafeArea(child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Block(color: Rb.panel, edge: Rb.panelEdge, depth: 6,
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const BlockText('BEFORE YOUR JOURNEY', size: 20, stroke: 4),
              const SizedBox(height: 12),
              const Text('HakbangHero is for adults aged 18 and above. Read both documents before continuing.'),
              const SizedBox(height: 12),
              LegalConsentControls(terms: _terms, privacy: _privacy,
                submitted: _submitted, enabled: !_saving,
                onTermsChanged: (v) => setState(() => _terms = v),
                onPrivacyChanged: (v) => setState(() => _privacy = v)),
              const SizedBox(height: 16),
              NeonBlueButton(label: 'CONTINUE', loading: _saving, onTap: _continue),
            ]),
          ),
        ),
      ))),
    ),
  );
}
