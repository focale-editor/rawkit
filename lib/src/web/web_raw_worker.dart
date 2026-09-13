import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:rawkit/src/model/raw_backend_info.dart';
import 'package:rawkit/src/model/raw_develop_settings.dart';
import 'package:rawkit/src/model/raw_exception.dart';
import 'package:rawkit/src/model/raw_image.dart';
import 'package:rawkit/src/model/raw_metadata.dart';
import 'package:rawkit/src/model/raw_types.dart';
import 'package:rawkit/src/web/web_configuration.dart';
import 'package:web/web.dart' as web;

/// Result returned after a browser Worker has opened a RAW source.
final class WebRawWorkerStartResult {
  /// Creates an initialized browser Worker result.
  const WebRawWorkerStartResult({
    required this.client,
    required this.metadata,
    required this.backendInfo,
  });

  /// Client used for subsequent commands.
  final WebRawWorkerClient client;

  /// Metadata copied from WebAssembly memory.
  final RawMetadata metadata;

  /// WebAssembly backend diagnostics.
  final RawBackendInfo backendInfo;
}

/// Proxies asynchronous commands to one long-lived browser Worker.
final class WebRawWorkerClient {
  /// Wraps a Worker that has not opened its RAW source yet.
  WebRawWorkerClient._(this._worker);

  final web.Worker _worker;
  final Map<int, Completer<_WorkerResponse>> _pending = <int, Completer<_WorkerResponse>>{};

  int _nextRequestId = 1;
  bool _closed = false;
  bool _closing = false;
  Future<void>? _closeFuture;

  /// Starts a browser Worker backed by an ownership-safe copy of [bytes].
  static Future<WebRawWorkerStartResult> openMemory(Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw const RawIOException(message: 'The RAW memory buffer is empty.');
    }
    final web.Worker worker = web.Worker(
      '${webAssetBaseUrl}rawkit_web_worker.js'.toJS,
      web.WorkerOptions(type: 'module', name: 'RawKit decoder'),
    );
    final WebRawWorkerClient client = WebRawWorkerClient._(worker);
    final Completer<_WorkerResponse> ready = Completer<_WorkerResponse>();
    worker.onmessage = (web.MessageEvent event) {
      final JSAny? data = event.data;
      if (data == null || !data.isA<JSObject>()) {
        return;
      }
      final _WorkerResponse response = _WorkerResponse._(data as JSObject);
      if (response.type == 'ready' || response.type == 'startupError') {
        if (!ready.isCompleted) {
          ready.complete(response);
        }
        return;
      }
      client._completeResponse(response);
    }.toJS;
    worker.onerror = (web.Event event) {
      final RawBackendException exception = RawBackendException(
        message:
            'Could not start or communicate with the RawKit Web Worker at '
            '$webAssetBaseUrl.',
      );
      if (!ready.isCompleted) {
        ready.completeError(exception);
      }
      client.terminate();
    }.toJS;

    final Uint8List transferableBytes = Uint8List.fromList(bytes);
    final JSArrayBuffer buffer = transferableBytes.buffer.toJS;
    worker.postMessage(
      _OpenRequest(operation: 'open', bytes: buffer),
      <JSArrayBuffer>[buffer].toJS,
    );
    try {
      final _WorkerResponse response = await ready.future;
      if (response.type == 'startupError') {
        throw _deserializeError(response.error);
      }
      return WebRawWorkerStartResult(
        client: client,
        metadata: _deserializeMetadata(response.metadata),
        backendInfo: _deserializeBackend(response.backend),
      );
    } on Object {
      client.terminate();
      rethrow;
    }
  }

  /// Requests a developed preview or full-resolution image.
  Future<RawImage> render({
    required RawDevelopSettings settings,
    required RawBitDepth bitDepth,
    required RawColorSpace colorSpace,
    required bool preview,
    required int maximumWidth,
    required int maximumHeight,
  }) async {
    final _WorkerResponse response = await _request(
      _RenderRequest(
        id: _nextRequestId,
        operation: 'render',
        settings: _SettingsMessage(
          whiteBalance: settings.whiteBalance.index,
          temperature: settings.temperature,
          tint: settings.tint,
          exposure: settings.exposure,
          contrast: settings.contrast,
          highlights: settings.highlights,
          shadows: settings.shadows,
          whites: settings.whites,
          blacks: settings.blacks,
          saturation: settings.saturation,
          vibrance: settings.vibrance,
          demosaicQuality: settings.demosaicQuality.index,
          highlightRecovery: settings.highlightRecovery.index,
        ),
        bitDepth: bitDepth.index,
        colorSpace: colorSpace.index,
        preview: preview,
        maximumWidth: maximumWidth,
        maximumHeight: maximumHeight,
      ),
    );
    final JSArrayBuffer? pixels = response.pixels;
    if (pixels == null) {
      throw const RawBackendException(
        message: 'The RawKit Web Worker returned no pixel buffer.',
      );
    }
    final int width = response.width;
    final int height = response.height;
    final int channels = response.channels;
    final RawBitDepth returnedBitDepth = RawBitDepth.values[response.bitDepth];
    final int sampleCount = width * height * channels;
    final ByteBuffer buffer = pixels.toDart;
    final TypedData typedPixels = switch (returnedBitDepth) {
      RawBitDepth.uint8 => Uint8List.view(buffer, 0, sampleCount),
      RawBitDepth.uint16 => Uint16List.view(buffer, 0, sampleCount),
    };
    return RawImage.fromPixels(
      width: width,
      height: height,
      channels: channels,
      bitDepth: returnedBitDepth,
      colorSpace: RawColorSpace.values[response.colorSpace],
      pixels: typedPixels,
    );
  }

  /// Discards decoded preview and full-resolution caches.
  Future<void> clearCache() async {
    await _request(
      _CommandRequest(id: _nextRequestId, operation: 'clearCache'),
    );
  }

  /// Shuts down the Worker and releases its WebAssembly document.
  ///
  /// Concurrent and repeated calls share the same shutdown.
  Future<void> close() => _closeFuture ??= _shutDown();

  /// Performs the single shutdown shared by every [close] call.
  Future<void> _shutDown() async {
    if (_closed) {
      return;
    }
    _closing = true;
    try {
      await _request(_CommandRequest(id: _nextRequestId, operation: 'close'));
    } on RawBackendException {
      // A Worker that already exited has released its WebAssembly resources.
    } finally {
      terminate();
    }
  }

  /// Immediately terminates this Worker as a best-effort leak safeguard.
  void terminate() {
    if (_closed) {
      return;
    }
    _closed = true;
    _worker.terminate();
    _failPending(
      const RawStateException(message: 'The RAW document is closed.'),
    );
  }

  /// Sends one request and completes when its matching response arrives.
  Future<_WorkerResponse> _request(JSObject request) {
    final _CommandRequest command = request as _CommandRequest;
    if (_closed || (_closing && command.operation != 'close')) {
      throw const RawStateException(message: 'The RAW document is closed.');
    }
    final int requestId = command.id;
    _nextRequestId++;
    final Completer<_WorkerResponse> completer = Completer<_WorkerResponse>();
    _pending[requestId] = completer;
    _worker.postMessage(request);
    return completer.future;
  }

  /// Resolves the pending request identified by [response].
  void _completeResponse(_WorkerResponse response) {
    if (response.type != 'response') {
      return;
    }
    final Completer<_WorkerResponse>? completer = _pending.remove(response.id);
    if (completer == null) {
      return;
    }
    if (response.ok) {
      completer.complete(response);
    } else {
      completer.completeError(_deserializeError(response.error));
    }
  }

  /// Fails every outstanding operation after a Worker-level failure.
  void _failPending(Object error) {
    final List<Completer<_WorkerResponse>> pending = _pending.values.toList();
    _pending.clear();
    for (final Completer<_WorkerResponse> completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }
}

/// Converts Worker metadata into the immutable public model.
RawMetadata _deserializeMetadata(_MetadataMessage? metadata) {
  if (metadata == null) {
    throw const RawBackendException(
      message: 'The RawKit Web Worker returned invalid metadata.',
    );
  }
  final int timestamp = metadata.timestamp;
  return RawMetadata(
    cameraMake: _nullableString(metadata.cameraMake),
    cameraModel: _nullableString(metadata.cameraModel),
    normalizedCameraMake: _nullableString(metadata.normalizedCameraMake),
    normalizedCameraModel: _nullableString(metadata.normalizedCameraModel),
    lens: _nullableString(metadata.lens),
    lensMake: _nullableString(metadata.lensMake),
    iso: _positiveOrNull(metadata.iso),
    shutterSpeed: _positiveOrNull(metadata.shutterSpeed),
    aperture: _positiveOrNull(metadata.aperture),
    focalLength: _positiveOrNull(metadata.focalLength),
    timestamp: timestamp <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true),
    orientation: RawOrientation.fromExifValue(metadata.orientation),
    width: metadata.width,
    height: metadata.height,
    rawWidth: metadata.rawWidth,
    rawHeight: metadata.rawHeight,
  );
}

/// Converts Worker diagnostics into the public backend model.
RawBackendInfo _deserializeBackend(_BackendMessage? backend) {
  if (backend == null) {
    throw const RawBackendException(
      message: 'The RawKit Web Worker returned invalid backend diagnostics.',
    );
  }
  return RawBackendInfo(
    engine: backend.engine,
    runtimeVersion: backend.runtimeVersion,
    bundledVersion: backend.bundledVersion,
    apiVersion: backend.apiVersion,
  );
}

/// Recreates a typed RawKit exception from a Worker error payload.
RawException _deserializeError(_ErrorMessage? error) {
  if (error == null) {
    return const RawBackendException(
      message: 'The RawKit Web Worker returned an unknown error.',
    );
  }
  final String message = error.message;
  final int? code = error.hasCode ? error.code : null;
  return switch (error.kind) {
    'unsupportedFile' => RawUnsupportedFileException(
      message: message,
      code: code,
    ),
    'io' => RawIOException(message: message, code: code),
    'memory' => RawMemoryException(message: message, code: code),
    'state' => RawStateException(message: message, code: code),
    'settings' => RawSettingsException(message: message),
    'backend' => RawBackendException(message: message, code: code),
    _ => RawDecodeException(message: message, code: code),
  };
}

/// Normalizes an optional metadata string.
String? _nullableString(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Converts missing or invalid positive metadata numbers to `null`.
double? _positiveOrNull(double value) => value.isFinite && value > 0 ? value : null;

/// Message that transfers the initial RAW byte buffer to the Worker.
@JS()
extension type _OpenRequest._(JSObject _) implements JSObject {
  external factory _OpenRequest({
    required String operation,
    required JSArrayBuffer bytes,
  });
}

/// Base request carrying an operation and correlation identifier.
@JS()
extension type _CommandRequest._(JSObject _) implements JSObject {
  external factory _CommandRequest({required int id, required String operation});

  external int get id;
  external String get operation;
}

/// Render request serialized without Dart objects.
@JS()
extension type _RenderRequest._(JSObject _) implements _CommandRequest, JSObject {
  external factory _RenderRequest({
    required int id,
    required String operation,
    required _SettingsMessage settings,
    required int bitDepth,
    required int colorSpace,
    required bool preview,
    required int maximumWidth,
    required int maximumHeight,
  });
}

/// Development controls serialized for JavaScript.
@JS()
extension type _SettingsMessage._(JSObject _) implements JSObject {
  external factory _SettingsMessage({
    required int whiteBalance,
    required double temperature,
    required double tint,
    required double exposure,
    required double contrast,
    required double highlights,
    required double shadows,
    required double whites,
    required double blacks,
    required double saturation,
    required double vibrance,
    required int demosaicQuality,
    required int highlightRecovery,
  });
}

/// Generic response returned by the Worker protocol.
@JS()
extension type _WorkerResponse._(JSObject _) implements JSObject {
  external String get type;
  external int get id;
  external bool get ok;
  external _MetadataMessage? get metadata;
  external _BackendMessage? get backend;
  external _ErrorMessage? get error;
  external int get width;
  external int get height;
  external int get channels;
  external int get bitDepth;
  external int get colorSpace;
  external JSArrayBuffer? get pixels;
}

/// Metadata payload returned during Worker startup.
@JS()
extension type _MetadataMessage._(JSObject _) implements JSObject {
  external String? get cameraMake;
  external String? get cameraModel;
  external String? get normalizedCameraMake;
  external String? get normalizedCameraModel;
  external String? get lens;
  external String? get lensMake;
  external double get iso;
  external double get shutterSpeed;
  external double get aperture;
  external double get focalLength;
  external int get timestamp;
  external int get orientation;
  external int get width;
  external int get height;
  external int get rawWidth;
  external int get rawHeight;
}

/// Backend diagnostics returned during Worker startup.
@JS()
extension type _BackendMessage._(JSObject _) implements JSObject {
  external String get engine;
  external String get runtimeVersion;
  external String get bundledVersion;
  external int get apiVersion;
}

/// Serialized typed error returned by the Worker.
@JS()
extension type _ErrorMessage._(JSObject _) implements JSObject {
  external String get kind;
  external String get message;
  external bool get hasCode;
  external int get code;
}
