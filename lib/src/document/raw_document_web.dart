import 'dart:typed_data';

import 'package:rawkit/src/develop/settings_validation.dart';
import 'package:rawkit/src/model/raw_backend_info.dart';
import 'package:rawkit/src/model/raw_develop_settings.dart';
import 'package:rawkit/src/model/raw_exception.dart';
import 'package:rawkit/src/model/raw_image.dart';
import 'package:rawkit/src/model/raw_metadata.dart';
import 'package:rawkit/src/model/raw_types.dart';
import 'package:rawkit/src/web/web_raw_worker.dart';

/// An open browser RAW source with Web Worker-owned decoding and caches.
///
/// Create a document with [openMemory] and release it with [close]. LibRaw,
/// WebAssembly, and tonal processing stay inside a dedicated Web Worker so
/// expensive image work does not block the browser's user-interface thread.
final class RawDocument {
  RawDocument._({
    required WebRawWorkerClient worker,
    required this.metadata,
    required this.backendInfo,
  }) : _worker = worker {
    _finalizer.attach(this, worker, detach: this);
  }

  static final Finalizer<WebRawWorkerClient> _finalizer = Finalizer<WebRawWorkerClient>((worker) {
    worker.terminate();
  });

  final WebRawWorkerClient _worker;
  Future<void>? _closeFuture;

  /// Camera and capture metadata parsed while opening the source.
  final RawMetadata metadata;

  /// Diagnostics for the WebAssembly decoder bundled into the application.
  final RawBackendInfo backendInfo;

  /// Whether [close] has been requested.
  bool get isClosed => _closeFuture != null;

  /// Rejects filesystem paths because browsers cannot open arbitrary paths.
  static Future<RawDocument> openFile(String path) => Future<RawDocument>.error(
    UnsupportedError(
      'RawDocument.openFile is unavailable in browsers. Read the browser File '
      'as bytes and call RawDocument.openMemory instead.',
    ),
  );

  /// Opens RAW bytes in a dedicated Web Worker.
  ///
  /// RawKit transfers an ownership-safe copy to the Worker, so the caller may
  /// reuse or modify [bytes] after this future completes.
  static Future<RawDocument> openMemory(Uint8List bytes) async {
    final WebRawWorkerStartResult result = await WebRawWorkerClient.openMemory(
      bytes,
    );
    return RawDocument._(
      worker: result.client,
      metadata: result.metadata,
      backendInfo: result.backendInfo,
    );
  }

  /// Alias for [openMemory] that reads naturally at byte-oriented call sites.
  static Future<RawDocument> openBytes(Uint8List bytes) => openMemory(bytes);

  /// Renders a size-limited preview, reusing its linear decode when possible.
  Future<RawImage> renderPreview(
    RawDevelopSettings settings, {
    int maxWidth = 1600,
    int? maxHeight,
    RawBitDepth bitDepth = RawBitDepth.uint8,
    RawColorSpace colorSpace = RawColorSpace.srgb,
  }) {
    _ensureOpen();
    validateDevelopSettings(settings);
    if (maxWidth <= 0 || (maxHeight != null && maxHeight <= 0)) {
      throw const RawSettingsException(
        message: 'Preview dimensions must be positive.',
      );
    }
    return _worker.render(
      settings: settings,
      bitDepth: bitDepth,
      colorSpace: colorSpace,
      preview: true,
      maximumWidth: maxWidth,
      maximumHeight: maxHeight ?? 0x7fffffff,
    );
  }

  /// Renders the developed image at full decoded resolution.
  Future<RawImage> render(
    RawDevelopSettings settings, {
    RawBitDepth bitDepth = RawBitDepth.uint16,
    RawColorSpace colorSpace = RawColorSpace.srgb,
  }) {
    _ensureOpen();
    validateDevelopSettings(settings);
    return _worker.render(
      settings: settings,
      bitDepth: bitDepth,
      colorSpace: colorSpace,
      preview: false,
      maximumWidth: 0x7fffffff,
      maximumHeight: 0x7fffffff,
    );
  }

  /// Releases cached linear images while keeping the RAW source open.
  Future<void> clearCache() {
    _ensureOpen();
    return _worker.clearCache();
  }

  /// Releases WebAssembly memory and terminates the Web Worker.
  ///
  /// Calling this method more than once is safe and returns the same future.
  Future<void> close() {
    final Future<void>? existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _finalizer.detach(this);
    final Future<void> closing = _worker.close();
    _closeFuture = closing;
    return closing;
  }

  void _ensureOpen() {
    if (isClosed) {
      throw const RawStateException(message: 'The RAW document is closed.');
    }
  }
}
