import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/activity_model.dart';
import '../models/run_summary_export.dart';
import 'block_ui.dart';

/// The same painter is used for preview and PNG export, without any buttons.
class RunShareCard extends StatelessWidget {
  final RunSummaryExport summary;
  final ui.Image mascot;
  const RunShareCard({super.key, required this.summary, required this.mascot});

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1080 / 1350,
    child: CustomPaint(painter: RunShareCardPainter(summary, mascot)),
  );
}

class RunShareCardPainter extends CustomPainter {
  static const headingFont = 'HakbangExportHeading';
  static const bodyFont = 'HakbangExportBody';
  final RunSummaryExport summary;
  final ui.Image mascot;
  RunShareCardPainter(this.summary, this.mascot);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1080, size.height / 1350);
    final paint = Paint();
    void panel(Rect rect, Color color, {Color edge = Rb.panelEdge}) {
      paint.color = edge;
      canvas.drawRRect(RRect.fromRectAndRadius(rect.shift(const Offset(0, 8)), const Radius.circular(28)), paint);
      paint.color = color;
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(28)), paint);
    }
    void text(String value, double x, double y, double width, double fontSize,
        {Color color = Colors.white, bool heading = false, TextAlign align = TextAlign.left}) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: TextStyle(color: color,
          fontFamily: heading ? headingFont : bodyFont, fontSize: fontSize,
          fontWeight: heading ? FontWeight.w400 : FontWeight.w800, height: 1.15)),
        textDirection: TextDirection.ltr, textAlign: align,
      )..layout(minWidth: width, maxWidth: width);
      painter.paint(canvas, Offset(x, y));
      painter.dispose();
    }
    paint.color = Rb.bg;
    canvas.drawRect(const Rect.fromLTWH(0, 0, 1080, 1350), paint);
    paint.color = Rb.neon;
    canvas.drawRect(const Rect.fromLTWH(0, 0, 1080, 16), paint);
    text('HAKBANGHERO', 52, 52, 976, 74, color: Rb.neon, heading: true);
    text('EVERY STEP COUNTS', 56, 142, 972, 24);
    panel(const Rect.fromLTWH(48, 204, 984, 328), Rb.panel);
    text(summary.result, 76, 238, 630, 38, color: Rb.gold, heading: true);
    text('${summary.type.label.toUpperCase()}  |  ${summary.date}', 78, 300, 620, 26);
    text(summary.mode, 78, 348, 620, 30);
    text('SAVED RUN', 78, 445, 620, 26, color: Rb.neon);
    // A fixed brand mascot avoids displaying a player's BMI-derived body form.
    final fitted = applyBoxFit(BoxFit.contain,
        Size(mascot.width.toDouble(), mascot.height.toDouble()), const Size(230, 292));
    final target = Alignment.center.inscribe(fitted.destination, const Rect.fromLTWH(770, 220, 230, 292));
    canvas.drawImageRect(mascot, Rect.fromLTWH(0, 0, mascot.width.toDouble(), mascot.height.toDouble()), target,
        Paint()..filterQuality = FilterQuality.medium);
    panel(const Rect.fromLTWH(48, 560, 984, 176), Rb.green, edge: Rb.greenEdge);
    text('DISTANCE', 76, 580, 928, 25, color: Colors.black);
    text('${summary.distanceKm.toStringAsFixed(2)} km', 76, 622, 928, 76, color: Colors.black, heading: true);
    void stat(String label, String value, double x, double y) {
      panel(Rect.fromLTWH(x, y, 480, 144), Rb.panel);
      text(label, x + 24, y + 20, 432, 23, color: Rb.silver);
      text(value, x + 24, y + 62, 432, 43, heading: true);
    }
    stat('DURATION', summary.duration, 48, 760);
    stat('AVG PACE', '${summary.pace} /km', 552, 760);
    stat('AVG SPEED', '${summary.averageSpeed.toStringAsFixed(1)} km/h', 48, 928);
    stat('MAX SPEED', '${summary.maximumSpeed.toStringAsFixed(1)} km/h', 552, 928);
    panel(const Rect.fromLTWH(48, 1100, 984, 152), Rb.gold, edge: Rb.goldEdge);
    text('CONFIRMED REWARDS', 72, 1120, 936, 24, color: Colors.black);
    text('+${summary.xp} XP', 72, 1168, 450, 46, color: Colors.black, heading: true);
    text('+${summary.coins} COINS', 540, 1168, 468, 46, color: Colors.black, heading: true);
    text('RUN  |  WALK  |  LEVEL UP', 48, 1290, 984, 24, color: Rb.silver, align: TextAlign.center);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant RunShareCardPainter old) =>
      old.summary != summary || old.mascot != mascot;
}
