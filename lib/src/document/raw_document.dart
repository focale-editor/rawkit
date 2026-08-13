import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../develop/settings_validation.dart';
import '../model/raw_backend_info.dart';
import '../model/raw_develop_settings.dart';
import '../model/raw_exception.dart';
import '../model/raw_image.dart';
import '../model/raw_metadata.dart';
import '../model/raw_types.dart';
import '../worker/raw_worker.dart';

/// An open RAW source with isolated decoding and reusable linear-image caches.
///
/// Create a document with [openFile] or [openMemory] and release it with
/// [close]. Native decoding and tonal processing run on a dedicated worker
/// isolate, so calls do not execute expensive image work on the caller's
/// isolate.
final class RawDocument {
  RawDocument._({
    required RawWorkerClient worker,
    required this.metadata,
    required this.backendInfo,
  }) : _worker = worker {
    _finalizer.attach(this, worker.commandPort, detach: this);
  }

  static final Finalizer<SendPort> _finalizer = Finalizer<SendPort>((port) {
    port.send(const {'id': -1, 'operation': 'close'});
  });

  final RawWorkerClient _worker;
  Future<void>? _closeFuture;

  /// Camera and capture metadata parsed while opening the source.
  final RawMetadata metadata;

  /// Diagnostics for the native decoder bundled into the application.
  final RawBackendInfo backendInfo;

  /// Whether [close] has been requested.
  bool get isClosed => _closeFuture != null;

  /// Opens and parses a RAW file without blocking the caller's isolate.
  static Future<RawDocument> openFile(String path) async {
    final RawWorkerStartResult result = await RawWorkerClient.openFile(path);
    return RawDocument._(
      worker: result.client,
      metadata: result.metadata,
      backendInfo: result.backendInfo,
    );
  }

  /// Opens RAW bytes after transferring them to a dedicated worker isolate.
  ///
  /// Both the isolate boundary and the native shim take ownership-safe copies;
  /// the caller may reuse or modify [bytes] after this future completes.
  static Future<RawDocument> openMemory(Uint8List bytes) async {
    final RawWorkerStartResult result = await RawWorkerClient.openMemory(bytes);
    return RawDocument._(
      worker: result.client,
      metadata: result.metadata,
      backendInfo: result.backendInfo,
    );
  }

  /// Alias for [openMemory] that reads naturally at byte-oriented call sites.
  static Future<RawDocument> openBytes(Uint8List bytes) => openMemory(bytes);

  /// Renders a size-limited preview, reusing its linear decode when possible.
  ///
  /// Changes to exposure, contrast, highlights, shadows, whites, blacks,
  /// saturation, or vibrance reuse the cached decode. White balance,
  /// demosaicing, highlight recovery, and color space trigger a new decode.
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
  ///
  /// The returned pixel dimensions account for the camera's display
  /// orientation; callers must not rotate them again using metadata.
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

  /// Releases native memory and terminates the worker isolate.
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
