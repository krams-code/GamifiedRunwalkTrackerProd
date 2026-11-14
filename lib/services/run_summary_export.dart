import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../models/run_summary_export.dart';
import '../widgets/run_share_card.dart';

class RunImageResult {
  final String message;
  const RunImageResult(this.message);
}

/// Read/render/export only. This service never writes run or reward data.
abstract final class RunSummaryExportService {
  static Future<void>? _fonts;

  static RunSummaryExport confirmed(DocumentSnapshot<Map<String, dynamic>> doc) {
    if (!doc.exists || doc.metadata.hasPendingWrites || doc.metadata.isFromCache) {
      throw StateError('Sharing is available after this run syncs with the server.');
    }
    return RunSummaryExport.fromRecord(doc.data()!);
  }

  static Future<void> _loadFonts() async {
    final heading = FontLoader(RunShareCardPainter.headingFont)
      ..addFont(rootBundle.load('assets/fonts/LilitaOne-Regular.ttf'));
    final body = FontLoader(RunShareCardPainter.bodyFont)
      ..addFont(rootBundle.load('assets/fonts/Nunito-ExtraBold.ttf'));
    await Future.wait([heading.load(), body.load()]);
  }

  static Future<Uint8List> render(RunSummaryExport summary) async {
    try {
      await (_fonts ??= _loadFonts());
    } catch (_) {
      _fonts = null;
      rethrow;
    }
    final data = await rootBundle.load('assets/images/heroes/sprout/normal/full.png');
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    final mascot = (await codec.getNextFrame()).image;
    codec.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    RunShareCardPainter(summary, mascot).paint(canvas, const ui.Size(1080, 1350));
    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(1080, 1350);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Could not create the image.');
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image?.dispose();
      picture.dispose();
      mascot.dispose();
    }
  }

  static Future<RunImageResult> share(Uint8List png, String name, ui.Rect origin,
      {Future<ShareResult> Function(ShareParams)? send}) async {
    final result = await (send ?? SharePlus.instance.share)(ShareParams(
      files: [XFile.fromData(png, mimeType: 'image/png', name: name)],
      fileNameOverrides: [name], title: 'HakbangHero run summary',
      sharePositionOrigin: origin, downloadFallbackEnabled: false,
    ));
    return RunImageResult(switch (result.status) {
      ShareResultStatus.success => 'Image handed to the selected app. Publication is not confirmed.',
      ShareResultStatus.dismissed => 'Sharing cancelled.',
      ShareResultStatus.unavailable => 'The system did not provide a sharing completion result.',
    });
  }

  static Future<RunImageResult> save(Uint8List png, String name,
      {Future<Uri?> Function(Uint8List, String)? saveFile, bool? browser}) async {
    final path = await (saveFile ?? _saveFile)(png, name);
    if (browser ?? kIsWeb) {
      return const RunImageResult('Download requested. Check your browser downloads; this does not confirm a Photos save.');
    }
    return RunImageResult(path == null ? 'Saving cancelled.' : 'Image exported to your selected file destination.');
  }

  static Future<Uri?> _saveFile(Uint8List png, String name) => FilePicker.saveFile(
    dialogTitle: 'Save run image', fileName: name, bytes: png,
    mimeType: 'image/png',
  );
}
