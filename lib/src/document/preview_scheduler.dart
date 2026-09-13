import 'dart:async';

import 'package:rawkit/src/model/raw_exception.dart';
import 'package:rawkit/src/model/raw_image.dart';

/// Coalesces preview renders so only the newest waiting request runs.
///
/// At most one preview is sent to the worker at a time. While it runs, a new
/// request waits; a later request replaces the waiting one, whose future fails
/// with [RawCancelledException]. Interactive controls therefore never queue a
/// backlog of stale previews.
final class PreviewScheduler {
  /// Whether a preview is currently being rendered by the worker.
  bool _isRendering = false;

  /// Newest preview waiting for the current render to finish.
  _WaitingPreview? _waiting;

  /// Runs [render] now, or after the current preview if one is in progress.
  Future<RawImage> schedule(Future<RawImage> Function() render) {
    if (!_isRendering) {
      return _start(render);
    }
    final _WaitingPreview? replaced = _waiting;
    final _WaitingPreview waiting = _WaitingPreview(render);
    _waiting = waiting;
    replaced?.completer.completeError(
      const RawCancelledException(
        message: 'A newer preview request replaced this one.',
      ),
    );
    return waiting.completer.future;
  }

  /// Fails the waiting preview, if any, with [RawCancelledException].
  void cancelWaiting() {
    final _WaitingPreview? waiting = _waiting;
    _waiting = null;
    waiting?.completer.completeError(
      const RawCancelledException(
        message: 'The RAW document closed before this preview started.',
      ),
    );
  }

  /// Starts [render] and schedules the waiting preview once it settles.
  Future<RawImage> _start(Future<RawImage> Function() render) {
    _isRendering = true;
    final Future<RawImage> result = Future<RawImage>.sync(render);
    result.then<void>((_) => _startWaiting(), onError: (Object _) => _startWaiting());
    return result;
  }

  /// Starts the waiting preview after the current render settled.
  void _startWaiting() {
    _isRendering = false;
    final _WaitingPreview? waiting = _waiting;
    _waiting = null;
    if (waiting != null) {
      waiting.completer.complete(_start(waiting.render));
    }
  }
}

/// Preview request waiting for the worker to become available.
final class _WaitingPreview {
  /// Creates a waiting request for [render].
  _WaitingPreview(this.render);

  /// Sends the request to the worker.
  final Future<RawImage> Function() render;

  /// Completes with the rendered image or the cancellation.
  final Completer<RawImage> completer = Completer<RawImage>();
}
