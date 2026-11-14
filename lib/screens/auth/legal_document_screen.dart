import 'package:flutter/material.dart';
import '../../models/legal_documents.dart';
import '../../widgets/block_ui.dart';

class LegalDocumentScreen extends StatelessWidget {
  final LegalDocument document;
  const LegalDocumentScreen({super.key, required this.document});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Rb.bg,
    appBar: AppBar(title: Text(document.title), backgroundColor: Rb.panel),
    body: SafeArea(child: Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Version ${document.version}', style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Effective date: ${LegalDocuments.effectiveDate}'),
          const SizedBox(height: 16),
          SelectableText(document.text.trim(), style: const TextStyle(fontSize: 15, height: 1.5)),
        ]),
      ),
    ))),
  );
}
