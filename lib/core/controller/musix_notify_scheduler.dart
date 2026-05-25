import 'package:flutter/scheduler.dart';

/// Coalesces [MusixController] listener notifications to at most once per frame.
class MusixNotifyScheduler {
  MusixNotifyScheduler(this._flush);

  final void Function() _flush;
  bool _frameScheduled = false;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _frameScheduled = false;
  }

  void schedule() {
    if (_disposed) {
      return;
    }
    if (_frameScheduled) {
      return;
    }
    _frameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameScheduled = false;
      if (_disposed) {
        return;
      }
      _flush();
    });
  }

  /// Bypass batching when a synchronous listener pass is required.
  void flushNow() {
    if (_disposed) {
      return;
    }
    _frameScheduled = false;
    _flush();
  }
}
