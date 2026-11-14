import 'package:flutter/material.dart';
import '../models/legal_documents.dart';
import '../screens/auth/legal_document_screen.dart';
import 'block_ui.dart';

class LegalConsentControls extends StatelessWidget {
  final bool terms;
  final bool privacy;
  final bool submitted;
  final bool enabled;
  final ValueChanged<bool> onTermsChanged;
  final ValueChanged<bool> onPrivacyChanged;
  const LegalConsentControls({super.key, required this.terms, required this.privacy,
    required this.onTermsChanged, required this.onPrivacyChanged,
    this.submitted = false, this.enabled = true});

  Widget _row(BuildContext context, {required bool checked, required String prefix,
      required LegalDocument document, required ValueChanged<bool> onChanged}) =>
    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Checkbox(
        value: checked,
        activeColor: Rb.blue,
        side: BorderSide(color: submitted && !checked ? const Color(0xFFFF8A80) : Colors.white70),
        onChanged: enabled ? (value) => onChanged(value ?? false) : null,
      ),
      Expanded(child: Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 8),
        child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(prefix, style: const TextStyle(fontSize: 13)),
          InkWell(
            onTap: enabled ? () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => LegalDocumentScreen(document: document))) : null,
            child: Text(document.title, style: const TextStyle(
              fontSize: 13, color: Rb.blue, decoration: TextDecoration.underline)),
          ),
          const Text('.', style: TextStyle(fontSize: 13)),
        ]),
      )),
    ]);

  @override
  Widget build(BuildContext context) => Column(children: [
    _row(context, checked: terms, prefix: 'I agree to the ',
        document: LegalDocuments.terms, onChanged: onTermsChanged),
    _row(context, checked: privacy, prefix: 'I acknowledge that I have read the ',
        document: LegalDocuments.privacy, onChanged: onPrivacyChanged),
    if (submitted && (!terms || !privacy))
      const Padding(padding: EdgeInsets.only(top: 4),
        child: Text('Both selections are required to continue.',
          style: TextStyle(fontSize: 12, color: Color(0xFFFF8A80)))),
  ]);
}
