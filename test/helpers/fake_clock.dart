import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// A clock and timers that move only when a test moves them.
class FakeClock {
  DateTime now = DateTime.utc(2026, 5, 1, 10);
  final List<FakeTimer> timers = [];

  Timer timer(Duration after, void Function() run) {
    final created = FakeTimer(now.add(after), run);
    timers.add(created);
    return created;
  }

  int get pending => timers.where((t) => t.isActive).length;

  /// Moves time on by [by], running the timers that fall due, in order, and
  /// letting the work each starts settle before the next.
  Future<void> advance(Duration by) async {
    final end = now.add(by);
    while (true) {
      final due = timers.where((t) => t.isActive && !t.at.isAfter(end)).toList()..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final next = due.first;
      if (next.at.isAfter(now)) now = next.at;
      next.fire();
      await pumpEventQueue();
    }
    now = end;
    await pumpEventQueue();
  }
}

class FakeTimer implements Timer {
  final DateTime at;
  final void Function() run;
  bool _active = true;

  FakeTimer(this.at, this.run);

  void fire() {
    _active = false;
    run();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
