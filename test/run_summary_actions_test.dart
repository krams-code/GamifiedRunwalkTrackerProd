import 'dart:async';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakbanghero/widgets/block_ui.dart';
import 'package:hakbanghero/widgets/run_summary_actions.dart';

class _Metadata extends Fake implements SnapshotMetadata {
  @override
  bool get hasPendingWrites => false;
  @override
  bool get isFromCache => false;
}

// ignore: subtype_of_sealed_class
class _Snapshot extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  @override
  bool get exists => true;
  @override
  SnapshotMetadata get metadata => _Metadata();
  @override
  Map<String, dynamic> data() => {
    'type': 'run', 'mode': 'stage_novice',
    'endTime': Timestamp.fromDate(DateTime(2026, 11, 15)),
    'durationSeconds': 1200, 'distanceKm': 2.0,
    'avgSpeedKmh': 6.0, 'maxSpeedKmh': 12.0,
    'awardedXp': 299, 'awardedCoins': 170,
  };
}

void main() {
  for (final action in ['RETRY', 'Share', 'Save Image']) {
  testWidgets('$action recovers a stalled image render and enables both buttons', (tester) async {
    final renders = <Completer<Uint8List>>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RunSummaryActions(
      ownerUid: 'runner', runId: 'run',
      activityStream: () => Stream.value(_Snapshot()),
      renderImage: (_) {
        final render = Completer<Uint8List>();
        renders.add(render);
        return render.future;
      },
    ))));
    await tester.pump();
    expect(renders, hasLength(1));
    await tester.pump(const Duration(seconds: 21));
    await tester.pump();
    expect(find.text('RETRY'), findsOneWidget);
    await tester.tap(find.text(action));
    await tester.pump();
    expect(renders, hasLength(2));
    renders[1].complete(Uint8List.fromList([1, 2, 3]));
    await tester.pump();
    final buttons = tester.widgetList<PressBlock>(find.byType(PressBlock));
    expect(buttons, hasLength(2));
    expect(buttons.every((button) => button.onTap != null), isTrue);
    expect(find.text('RETRY'), findsNothing);
    // A late completion from the abandoned attempt cannot change the image.
    renders[0].complete(Uint8List(0));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  }
}
