import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hakbanghero/models/run_summary_export.dart';
import 'package:hakbanghero/services/run_summary_export.dart';

Map<String, dynamic> record() => {
  'type': 'run', 'endTime': Timestamp.fromDate(DateTime(2026, 11, 14)),
  'durationSeconds': 1234, 'distanceKm': 3.25, 'avgSpeedKmh': 9.48,
  'maxSpeedKmh': 13.4, 'xpEarned': 400, 'coinsEarned': 33,
  'awardedXp': 400, 'awardedCoins': 1, 'mode': 'endless',
  'email': 'private@example.com', 'weight_kg': 70, 'height_cm': 170,
  'routePoints': [{'lat': 14.3, 'lng': 121.1}],
};

class _Metadata extends Fake implements SnapshotMetadata {
  _Metadata({this.pending = false, this.cached = false});
  final bool pending, cached;
  @override
  bool get hasPendingWrites => pending;
  @override
  bool get isFromCache => cached;
}

// ignore: subtype_of_sealed_class
class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.value, this.metadata);
  final Map<String, dynamic>? value;
  @override
  final SnapshotMetadata metadata;
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only server-confirmed records with reward receipts can be exported', () {
    final saved = RunSummaryExportService.confirmed(_Snapshot(record(), _Metadata()));
    expect(saved.xp, 400);
    expect(saved.coins, 1, reason: 'Use credited coins, including the daily cap, not base coins.');
    expect(saved.duration, '20:34');
    expect(saved.date, '2026-11-14');
    for (final snapshot in [
      _Snapshot(null, _Metadata()),
      _Snapshot(record(), _Metadata(pending: true)),
      _Snapshot(record(), _Metadata(cached: true)),
      _Snapshot(record()..remove('awardedCoins'), _Metadata()),
    ]) {
      expect(() => RunSummaryExportService.confirmed(snapshot), throwsStateError);
    }
  });

  test('untrusted strings and private profile/route data do not enter the export model', () {
    final data = record()..['mode'] = 'private@example.com'..['stage_result'] = '14.3,121.1';
    final saved = RunSummaryExport.fromRecord(data);
    expect(saved.mode, 'Run session');
    expect(saved.result, 'SESSION COMPLETE');
    expect(saved.fileName, 'hakbanghero_2026-11-14.png');
    expect(data['routePoints'], isNotEmpty, reason: 'Export does not modify source data.');
  });

  test('share delegates the prepared PNG and reports handoff, not publication', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final result = await RunSummaryExportService.share(bytes, 'run.png', const ui.Rect.fromLTWH(1, 2, 48, 48),
      send: (params) async {
        expect(params.downloadFallbackEnabled, isFalse);
        expect(params.files!.single.mimeType, 'image/png');
        expect(await params.files!.single.readAsBytes(), bytes);
        expect(params.fileNameOverrides, ['run.png']);
        return const ShareResult('app', ShareResultStatus.success);
      });
    expect(result.message, contains('Publication is not confirmed'));
    final cancel = await RunSummaryExportService.share(bytes, 'run.png', ui.Rect.zero,
      send: (_) async => const ShareResult('', ShareResultStatus.dismissed));
    expect(cancel.message, 'Sharing cancelled.');
    await expectLater(RunSummaryExportService.share(bytes, 'run.png', ui.Rect.zero,
      send: (_) async => throw UnsupportedError('No sharing')), throwsUnsupportedError);
  });

  test('save distinguishes native confirmation/cancellation from a browser download request', () async {
    final bytes = Uint8List(1);
    final cancelled = await RunSummaryExportService.save(bytes, 'run.png', browser: false,
      saveFile: (_, name) async => null);
    expect(cancelled.message, 'Saving cancelled.');
    final saved = await RunSummaryExportService.save(bytes, 'run.png', browser: false,
      saveFile: (_, name) async => Uri.parse('content://files/run.png'));
    expect(saved.message, contains('selected file destination'));
    final download = await RunSummaryExportService.save(bytes, 'run.png', browser: true,
      saveFile: (_, name) async => null);
    expect(download.message, startsWith('Download requested.'));
    await expectLater(RunSummaryExportService.save(bytes, 'run.png', browser: false,
      saveFile: (_, name) async => throw StateError('Storage failed')), throwsStateError);
  });

  test('PNG is readable, opaque, and exactly 1080 by 1350', () async {
    final bytes = await RunSummaryExportService.render(RunSummaryExport.fromRecord(record()));
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final codec = await ui.instantiateImageCodec(bytes);
    final image = (await codec.getNextFrame()).image;
    expect(image.width, 1080);
    expect(image.height, 1350);
    final pixels = await image.toByteData();
    expect(pixels!.getUint8(3), 255);
    image.dispose();
    codec.dispose();
    await Directory('build').create(recursive: true);
    await File('build/test_run_share.png').writeAsBytes(bytes);
  });
}
