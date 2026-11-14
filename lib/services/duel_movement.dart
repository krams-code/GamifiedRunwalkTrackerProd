import 'dart:math' as math;
import '../models/duel_policy.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class DuelFix {
  final double latitude, longitude, accuracy;
  final DateTime at;
  final bool mocked;
  const DuelFix(this.latitude, this.longitude, this.accuracy, this.at, {this.mocked = false});
}

/// Conservative evidence from raw fixes, before the normal distance filter.
/// Accuracy is an estimate; this is not independent proof of real movement.
class DuelMovement {
  DuelFix? _last, _windowStart;
  int _fixes = 0;
  double _gap = 0;
  bool _jumpAnchorUsed = false;
  bool invalid = false;
  final List<Map<String, dynamic>> _windows = [], _jumps = [];

  Map<String, dynamic> get evidence => {
    'invalid': invalid, if (_last != null) 'observed_at': Timestamp.fromDate(_last!.at), 'windows': [for (final w in _windows) {...w}],
    'jumps': [for (final j in _jumps) {...j}],
  };

  void _resetWindow() { _windowStart = null; _fixes = 0; _gap = 0; _windows.clear(); }

  static double _distance(DuelFix a, DuelFix b) {
    final p = math.pi / 180;
    final s = math.pow(math.sin((b.latitude - a.latitude) * p / 2), 2) +
        math.cos(a.latitude * p) * math.cos(b.latitude * p) *
        math.pow(math.sin((b.longitude - a.longitude) * p / 2), 2);
    return 6371000 * 2 * math.asin(math.sqrt(s.clamp(0, 1)));
  }

  void add(DuelFix fix, {required DateTime now}) {
    if (invalid) return;
    if (fix.mocked || !fix.latitude.isFinite || fix.latitude.abs() > 90 ||
        !fix.longitude.isFinite || fix.longitude.abs() > 180 ||
        !fix.accuracy.isFinite || fix.accuracy <= 0 || fix.accuracy > DuelPolicy.evidenceAccuracyM ||
        fix.at.isAfter(now) || now.difference(fix.at).inSeconds > DuelPolicy.fixAgeSeconds) {
      _resetWindow(); _last = null; _jumpAnchorUsed = false;
      return;
    }
    final previous = _last;
    if (previous != null && !fix.at.isAfter(previous.at)) return;
    if (previous != null) {
      final dt = fix.at.difference(previous.at).inMilliseconds / 1000.0;
      final meters = math.max(0.0, _distance(previous, fix) - previous.accuracy - fix.accuracy);
      final at = fix.at.millisecondsSinceEpoch / 1000.0;
      _jumps.removeWhere((j) => at - (j['at'] as num) > DuelPolicy.jumpPeriodSeconds);
      final jump = !_jumpAnchorUsed && dt >= DuelPolicy.jumpMinSeconds && dt <= DuelPolicy.jumpMaxSeconds &&
          meters > DuelPolicy.jumpMeters && meters / dt * 3.6 > DuelPolicy.jumpSpeedKmh;
      _jumpAnchorUsed = jump;
      if (jump) _jumps.add({'meters': meters, 'seconds': dt, 'at': at});
      if (dt > DuelPolicy.windowGapSeconds || jump) {
        _resetWindow();
      } else {
        _gap = math.max(_gap, dt);
      }
    }
    _last = fix;
    _windowStart ??= fix;
    _fixes++;
    final first = _windowStart!;
    final seconds = fix.at.difference(first.at).inMilliseconds / 1000.0;
    if (seconds >= DuelPolicy.windowSeconds) {
      final speed = math.max(0.0, _distance(first, fix) - first.accuracy - fix.accuracy) / seconds * 3.6;
      if (_fixes >= DuelPolicy.windowFixes && _gap <= DuelPolicy.windowGapSeconds && speed > DuelPolicy.excessiveSpeedKmh) {
        _windows.add({'seconds': seconds, 'speed': speed, 'fixes': _fixes, 'gap': _gap});
      } else {
        _windows.clear();
      }
      _windowStart = fix; _fixes = 1; _gap = 0;
    }
    invalid = DuelPolicy.invalidEvidence(evidence);
  }
}
