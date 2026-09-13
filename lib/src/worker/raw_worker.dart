import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:rawkit/src/develop/linear_image.dart';
import 'package:rawkit/src/develop/render_geometry.dart';
import 'package:rawkit/src/develop/tone_processor.dart';
import 'package:rawkit/src/model/raw_backend_info.dart';
import 'package:rawkit/src/model/raw_develop_settings.dart';
import 'package:rawkit/src/model/raw_exception.dart';
import 'package:rawkit/src/model/raw_image.dart';
import 'package:rawkit/src/model/raw_metadata.dart';
import 'package:rawkit/src/model/raw_types.dart';
import 'package:rawkit/src/native/native_backend.dart';

/// Result returned after a worker has opened and parsed a RAW source.
final class RawWorkerStartResult {
  /// Creates an initialized worker result.
  const RawWorkerStartResult({
    required this.client,
    required this.metadata,
    required this.backendInfo,
  });

  /// Client used for subsequent commands.
  final RawWorkerClient client;

  /// Metadata copied from the worker.
  final RawMetadata metadata;

  /// Native backend diagnostics.
  final RawBackendInfo backendInfo;
}

/// Proxies asynchronous commands to one long-lived decoder isolate.
final class RawWorkerClient {
  RawWorkerClient._({
    required this._isolate,
    required this._events,
    required this._errors,
    required this._exits,
  });

  final Isolate _isolate;
  final ReceivePort _events;
  final ReceivePort _errors;
  final ReceivePort _exits;
  final Map<int, Completer<Map<Object?, Object?>>> _pending = {};

  late final StreamSubscription<Object?> _eventSubscription;
  late final StreamSubscription<Object?> _errorSubscription;
  late final StreamSubscription<Object?> _exitSubscription;
  late SendPort _commandPort;
  int _nextRequestId = 1;
  bool _closed = false;
  bool _closing = false;
  Future<void>? _disposeFuture;
  Future<void>? _closeFuture;

  /// Starts a worker backed by a filesystem path.
  static Future<RawWorkerStartResult> openFile(String path) => _start({'kind': 'file', 'path': path});

  /// Starts a worker backed by bytes transferred into its isolate.
  static Future<RawWorkerStartResult> openMemory(Uint8List bytes) => _start({
    'kind': 'memory',
    'bytes': TransferableTypedData.fromList([bytes]),
  });

  static Future<RawWorkerStartResult> _start(
    Map<Object?, Object?> source,
  ) async {
    final ReceivePort events = ReceivePort();
    final ReceivePort errors = ReceivePort();
    final ReceivePort exits = ReceivePort();
    final Completer<Map<Object?, Object?>> ready = Completer<Map<Object?, Object?>>();
    late RawWorkerClient client;
    late final Isolate isolate;
    try {
      isolate = await Isolate.spawn<Map<Object?, Object?>>(
        rawWorkerMain,
        {'replyPort': events.sendPort, 'source': source},
        onError: errors.sendPort,
        onExit: exits.sendPort,
        errorsAreFatal: true,
        debugName: 'RawKit decoder',
      );
    } on Object catch (error) {
      events.close();
      errors.close();
      exits.close();
      throw RawBackendException(
        message: 'Could not start the RAW worker isolate.',
        cause: error,
      );
    }
    client = RawWorkerClient._(
      isolate: isolate,
      events: events,
      errors: errors,
      exits: exits,
    );
    client._eventSubscription = events.listen((message) {
      if (message is! Map<Object?, Object?>) {
        return;
      }
      final Object? type = message['type'];
      if (type == 'ready' || type == 'startupError') {
        if (!ready.isCompleted) {
          ready.complete(message);
        }
        return;
      }
      if (type == 'response') {
        client._completeResponse(message);
      }
    });
    client._errorSubscription = errors.listen((message) {
      final RawBackendException exception = RawBackendException(
        message: 'The RAW worker isolate failed: $message',
      );
      if (!ready.isCompleted) {
        ready.completeError(exception);
      }
      client._failPending(exception);
    });
    client._exitSubscription = exits.listen((message) {
      if (!ready.isCompleted) {
        ready.completeError(
          const RawBackendException(
            message: 'The RAW worker exited before initialization completed.',
          ),
        );
      }
      client._failPending(
        RawBackendException(
          message: client._closing ? 'The RAW worker exited while shutting down.' : 'The RAW worker exited unexpectedly.',
        ),
      );
      client._closed = true;
      unawaited(client._disposePorts());
    });

    try {
      final Map<Object?, Object?> message = await ready.future;
      if (message['type'] == 'startupError') {
        throw deserializeRawException(message['error']);
      }
      final Object? commandPort = message['commandPort'];
      if (commandPort is! SendPort) {
        throw const RawBackendException(
          message: 'The RAW worker returned an invalid command port.',
        );
      }
      client._commandPort = commandPort;
      return RawWorkerStartResult(
        client: client,
        metadata: deserializeMetadata(message['metadata']),
        backendInfo: deserializeBackendInfo(message['backend']),
      );
    } on Object {
      client._closing = true;
      isolate.kill(priority: Isolate.immediate);
      await client._disposePorts();
      rethrow;
    }
  }

  /// Port used by the document finalizer for best-effort shutdown.
  SendPort get commandPort => _commandPort;

  /// Requests a developed preview or full-resolution image.
  Future<RawImage> render({
    required RawDevelopSettings settings,
    required RawBitDepth bitDepth,
    required RawColorSpace colorSpace,
    required bool preview,
    required int maximumWidth,
    required int maximumHeight,
  }) async {
    final Map<Object?, Object?> response = await _request('render', {
      'settings': serializeSettings(settings),
      'bitDepth': bitDepth.index,
      'colorSpace': colorSpace.index,
      'preview': preview,
      'maximumWidth': maximumWidth,
      'maximumHeight': maximumHeight,
    });
    final Object? transferred = response['pixels'];
    if (transferred is! TransferableTypedData) {
      throw const RawBackendException(
        message: 'The RAW worker returned an invalid pixel buffer.',
      );
    }
    final ByteBuffer buffer = transferred.materialize();
    final RawBitDepth returnedBitDepth = RawBitDepth.values[_integer(response['bitDepth'], 'bitDepth')];
    final int width = _integer(response['width'], 'width');
    final int height = _integer(response['height'], 'height');
    final int channels = _integer(response['channels'], 'channels');
    final int sampleCount = width * height * channels;
    final TypedData pixels = switch (returnedBitDepth) {
      RawBitDepth.uint8 => Uint8List.view(buffer, 0, sampleCount),
      RawBitDepth.uint16 => Uint16List.view(buffer, 0, sampleCount),
    };
    return RawImage.fromPixels(
      width: width,
      height: height,
      channels: channels,
      bitDepth: returnedBitDepth,
      colorSpace: RawColorSpace.values[_integer(response['colorSpace'], 'colorSpace')],
      pixels: pixels,
    );
  }

  /// Discards decoded preview and full-resolution caches.
  Future<void> clearCache() async {
    await _request('clearCache');
  }

  /// Shuts down the worker and releases the native document.
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
      await _request('close');
    } on RawBackendException {
      // An isolate that already exited has released its native resources.
    } finally {
      _closed = true;
      _isolate.kill(priority: Isolate.beforeNextEvent);
      await _disposePorts();
    }
  }

  Future<Map<Object?, Object?>> _request(
    String operation, [
    Map<Object?, Object?> arguments = const {},
  ]) {
    if (_closed || (_closing && operation != 'close')) {
      throw const RawStateException(message: 'The RAW document is closed.');
    }
    final int requestId = _nextRequestId++;
    final Completer<Map<Object?, Object?>> completer = Completer<Map<Object?, Object?>>();
    _pending[requestId] = completer;
    _commandPort.send({'id': requestId, 'operation': operation, ...arguments});
    return completer.future;
  }

  void _completeResponse(Map<Object?, Object?> message) {
    final Object? rawId = message['id'];
    if (rawId is! int) {
      return;
    }
    final Completer<Map<Object?, Object?>>? completer = _pending.remove(rawId);
    if (completer == null) {
      return;
    }
    if (message['ok'] == true) {
      completer.complete(message);
    } else {
      completer.completeError(deserializeRawException(message['error']));
    }
  }

  void _failPending(Object error) {
    final List<Completer<Map<Object?, Object?>>> pending = _pending.values.toList();
    _pending.clear();
    for (final Completer<Map<Object?, Object?>> completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }

  Future<void> _disposePorts() {
    final Future<void>? existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }
    final Future<void> disposing = _disposePortsOnce();
    _disposeFuture = disposing;
    return disposing;
  }

  Future<void> _disposePortsOnce() async {
    await _eventSubscription.cancel();
    await _errorSubscription.cancel();
    await _exitSubscription.cancel();
    _events.close();
    _errors.close();
    _exits.close();
  }
}

/// Entry point for the long-lived RAW decoder isolate.
@pragma('vm:entry-point')
Future<void> rawWorkerMain(Map<Object?, Object?> startup) async {
  final Object? rawReplyPort = startup['replyPort'];
  if (rawReplyPort is! SendPort) {
    return;
  }
  final SendPort replyPort = rawReplyPort;
  final ReceivePort commands = ReceivePort();
  NativeRawDocument? document;
  try {
    final Object? rawSource = startup['source'];
    if (rawSource is! Map<Object?, Object?>) {
      throw const RawBackendException(
        message: 'The RAW worker received an invalid source.',
      );
    }
    document = _openNativeSource(rawSource);
    replyPort.send({
      'type': 'ready',
      'commandPort': commands.sendPort,
      'metadata': serializeMetadata(document.metadata),
      'backend': serializeBackendInfo(NativeRawDocument.backendInfo()),
    });

    final _LinearImageCaches caches = _LinearImageCaches();

    NativeRawDocument requireDocument() {
      final NativeRawDocument? current = document;
      if (current == null) {
        throw const RawStateException(message: 'The RAW document is closed.');
      }
      return current;
    }

    await for (final Object? rawCommand in commands) {
      if (rawCommand is! Map<Object?, Object?>) {
        continue;
      }
      final Object? rawId = rawCommand['id'];
      final Object? rawOperation = rawCommand['operation'];
      if (rawId is! int || rawOperation is! String) {
        continue;
      }
      bool shouldExit = false;
      try {
        switch (rawOperation) {
          case 'render':
            final RawDevelopSettings settings = deserializeSettings(
              rawCommand['settings'],
            );
            final RawColorSpace colorSpace = RawColorSpace.values[_integer(rawCommand['colorSpace'], 'colorSpace')];
            final int maximumWidth = _integer(rawCommand['maximumWidth'], 'maximumWidth');
            final int maximumHeight = _integer(rawCommand['maximumHeight'], 'maximumHeight');
            final NativeRawDocument current = requireDocument();
            final bool halfSize =
                _boolean(rawCommand['preview'], 'preview') &&
                halfSizeCoversPreview(
                  width: current.metadata.width,
                  height: current.metadata.height,
                  orientation: current.metadata.orientation,
                  maximumWidth: maximumWidth,
                  maximumHeight: maximumHeight,
                );
            final LinearImage linearImage = caches.developable(
              key: _DecodeCacheKey.fromSettings(settings, colorSpace),
              halfSize: halfSize,
              maximumWidth: maximumWidth,
              maximumHeight: maximumHeight,
              decode: () => current.decode(
                settings: settings,
                colorSpace: colorSpace,
                halfSize: halfSize,
              ),
            );
            final RawImage image = ToneProcessor.render(
              source: linearImage,
              settings: settings,
              bitDepth: RawBitDepth.values[_integer(rawCommand['bitDepth'], 'bitDepth')],
              maximumWidth: maximumWidth,
              maximumHeight: maximumHeight,
            );
            replyPort.send({
              'type': 'response',
              'id': rawId,
              'ok': true,
              'width': image.width,
              'height': image.height,
              'channels': image.channels,
              'bitDepth': image.bitDepth.index,
              'colorSpace': image.colorSpace.index,
              'pixels': TransferableTypedData.fromList([image.bytes]),
            });
          case 'clearCache':
            caches.clear();
            replyPort.send({'type': 'response', 'id': rawId, 'ok': true});
          case 'close':
            document?.close();
            document = null;
            replyPort.send({'type': 'response', 'id': rawId, 'ok': true});
            shouldExit = true;
          default:
            throw RawBackendException(
              message: 'Unknown RAW worker operation: $rawOperation.',
            );
        }
      } on Object catch (error) {
        replyPort.send({
          'type': 'response',
          'id': rawId,
          'ok': false,
          'error': serializeRawException(error),
        });
      }
      if (shouldExit) {
        break;
      }
    }
  } on Object catch (error) {
    replyPort.send({
      'type': 'startupError',
      'error': serializeRawException(error),
    });
  } finally {
    document?.close();
    commands.close();
  }
}

NativeRawDocument _openNativeSource(Map<Object?, Object?> source) => switch (source['kind']) {
  'file' => NativeRawDocument.openFile(_string(source['path'], 'path')),
  'memory' => NativeRawDocument.openMemory(
    _transferredBytes(source['bytes'], 'bytes'),
  ),
  _ => throw const RawBackendException(
    message: 'The RAW worker received an unsupported source kind.',
  ),
};

Uint8List _transferredBytes(Object? value, String name) {
  if (value is! TransferableTypedData) {
    throw RawBackendException(message: 'Worker field $name is invalid.');
  }
  return value.materialize().asUint8List();
}

/// Linear decodes and their last downscaled copy owned by the worker isolate.
final class _LinearImageCaches {
  /// Half-resolution decode used by previews.
  LinearImage? _half;

  /// Decoder controls that produced [_half].
  _DecodeCacheKey? _halfKey;

  /// Full-resolution decode used by renders and large previews.
  LinearImage? _full;

  /// Decoder controls that produced [_full].
  _DecodeCacheKey? _fullKey;

  /// Last area-averaged copy of [_resampledSource].
  LinearImage? _resampled;

  /// Decode from which [_resampled] was derived.
  LinearImage? _resampledSource;

  /// Returns a linear image sized for the requested bounds.
  ///
  /// The half- or full-resolution decode is reused while [key] matches, and a
  /// stale decode is released before [decode] allocates its replacement. When
  /// the bounds require downscaling, the last area-averaged copy is reused
  /// because it does not depend on tonal settings.
  LinearImage developable({
    required _DecodeCacheKey key,
    required bool halfSize,
    required int maximumWidth,
    required int maximumHeight,
    required LinearImage Function() decode,
  }) {
    final LinearImage decoded = halfSize ? _decodedHalf(key, decode) : _decodedFull(key, decode);
    final ({int width, int height}) dimensions = fitDimensions(
      width: decoded.width,
      height: decoded.height,
      maximumWidth: maximumWidth,
      maximumHeight: maximumHeight,
    );
    if (dimensions.width == decoded.width && dimensions.height == decoded.height) {
      return decoded;
    }
    final LinearImage? resampled = _resampled;
    if (resampled != null && identical(_resampledSource, decoded) && resampled.width == dimensions.width && resampled.height == dimensions.height) {
      return resampled;
    }
    _resampled = null;
    final LinearImage replacement = ToneProcessor.resample(
      decoded,
      dimensions.width,
      dimensions.height,
    );
    _resampled = replacement;
    _resampledSource = decoded;
    return replacement;
  }

  /// Returns the half-resolution decode for [key], decoding on a cache miss.
  LinearImage _decodedHalf(_DecodeCacheKey key, LinearImage Function() decode) {
    final LinearImage? cached = _half;
    if (cached != null && _halfKey == key) {
      return cached;
    }
    _releaseDerived(cached);
    _half = null;
    _halfKey = null;
    final LinearImage decoded = decode();
    _half = decoded;
    _halfKey = key;
    return decoded;
  }

  /// Returns the full-resolution decode for [key], decoding on a cache miss.
  LinearImage _decodedFull(_DecodeCacheKey key, LinearImage Function() decode) {
    final LinearImage? cached = _full;
    if (cached != null && _fullKey == key) {
      return cached;
    }
    _releaseDerived(cached);
    _full = null;
    _fullKey = null;
    final LinearImage decoded = decode();
    _full = decoded;
    _fullKey = key;
    return decoded;
  }

  /// Drops the downscaled copy when it was derived from [source].
  void _releaseDerived(LinearImage? source) {
    if (source != null && identical(_resampledSource, source)) {
      _resampled = null;
      _resampledSource = null;
    }
  }

  /// Releases every cached image.
  void clear() {
    _half = null;
    _halfKey = null;
    _full = null;
    _fullKey = null;
    _resampled = null;
    _resampledSource = null;
  }
}

/// Cache identity for the controls that require a new native development pass.
final class _DecodeCacheKey {
  const _DecodeCacheKey({
    required this.whiteBalance,
    required this.temperature,
    required this.tint,
    required this.demosaicQuality,
    required this.highlightRecovery,
    required this.colorSpace,
  });

  factory _DecodeCacheKey.fromSettings(
    RawDevelopSettings settings,
    RawColorSpace colorSpace,
  ) => _DecodeCacheKey(
    whiteBalance: settings.whiteBalance,
    temperature: settings.whiteBalance == RawWhiteBalance.custom ? settings.temperature : 0,
    tint: settings.whiteBalance == RawWhiteBalance.custom ? settings.tint : 0,
    demosaicQuality: settings.demosaicQuality,
    highlightRecovery: settings.highlightRecovery,
    colorSpace: colorSpace,
  );

  final RawWhiteBalance whiteBalance;
  final double temperature;
  final double tint;
  final RawDemosaicQuality demosaicQuality;
  final RawHighlightRecovery highlightRecovery;
  final RawColorSpace colorSpace;

  @override
  bool operator ==(Object other) =>
      other is _DecodeCacheKey &&
      whiteBalance == other.whiteBalance &&
      temperature == other.temperature &&
      tint == other.tint &&
      demosaicQuality == other.demosaicQuality &&
      highlightRecovery == other.highlightRecovery &&
      colorSpace == other.colorSpace;

  @override
  int get hashCode => Object.hash(
    whiteBalance,
    temperature,
    tint,
    demosaicQuality,
    highlightRecovery,
    colorSpace,
  );
}

/// Converts public settings into isolate-safe primitives.
Map<Object?, Object?> serializeSettings(RawDevelopSettings settings) => {
  'whiteBalance': settings.whiteBalance.index,
  'temperature': settings.temperature,
  'tint': settings.tint,
  'exposure': settings.exposure,
  'contrast': settings.contrast,
  'highlights': settings.highlights,
  'shadows': settings.shadows,
  'whites': settings.whites,
  'blacks': settings.blacks,
  'saturation': settings.saturation,
  'vibrance': settings.vibrance,
  'demosaicQuality': settings.demosaicQuality.index,
  'highlightRecovery': settings.highlightRecovery.index,
};

/// Reconstructs public settings from isolate-safe primitives.
RawDevelopSettings deserializeSettings(Object? raw) {
  final Map<Object?, Object?> values = _map(raw, 'settings');
  return RawDevelopSettings(
    whiteBalance: RawWhiteBalance.values[_integer(values['whiteBalance'], 'whiteBalance')],
    temperature: _double(values['temperature'], 'temperature'),
    tint: _double(values['tint'], 'tint'),
    exposure: _double(values['exposure'], 'exposure'),
    contrast: _double(values['contrast'], 'contrast'),
    highlights: _double(values['highlights'], 'highlights'),
    shadows: _double(values['shadows'], 'shadows'),
    whites: _double(values['whites'], 'whites'),
    blacks: _double(values['blacks'], 'blacks'),
    saturation: _double(values['saturation'], 'saturation'),
    vibrance: _double(values['vibrance'], 'vibrance'),
    demosaicQuality: RawDemosaicQuality.values[_integer(values['demosaicQuality'], 'demosaicQuality')],
    highlightRecovery: RawHighlightRecovery.values[_integer(values['highlightRecovery'], 'highlightRecovery')],
  );
}

/// Converts metadata into isolate-safe primitives.
Map<Object?, Object?> serializeMetadata(RawMetadata metadata) => {
  'cameraMake': metadata.cameraMake,
  'cameraModel': metadata.cameraModel,
  'normalizedCameraMake': metadata.normalizedCameraMake,
  'normalizedCameraModel': metadata.normalizedCameraModel,
  'lens': metadata.lens,
  'lensMake': metadata.lensMake,
  'iso': metadata.iso,
  'shutterSpeed': metadata.shutterSpeed,
  'aperture': metadata.aperture,
  'focalLength': metadata.focalLength,
  'timestamp': metadata.timestamp?.millisecondsSinceEpoch,
  'orientation': metadata.orientation.index,
  'width': metadata.width,
  'height': metadata.height,
  'rawWidth': metadata.rawWidth,
  'rawHeight': metadata.rawHeight,
};

/// Reconstructs metadata from isolate-safe primitives.
RawMetadata deserializeMetadata(Object? raw) {
  final Map<Object?, Object?> values = _map(raw, 'metadata');
  final int? timestamp = _nullableInteger(values['timestamp'], 'timestamp');
  return RawMetadata(
    cameraMake: _nullableString(values['cameraMake'], 'cameraMake'),
    cameraModel: _nullableString(values['cameraModel'], 'cameraModel'),
    normalizedCameraMake: _nullableString(
      values['normalizedCameraMake'],
      'normalizedCameraMake',
    ),
    normalizedCameraModel: _nullableString(
      values['normalizedCameraModel'],
      'normalizedCameraModel',
    ),
    lens: _nullableString(values['lens'], 'lens'),
    lensMake: _nullableString(values['lensMake'], 'lensMake'),
    iso: _nullableDouble(values['iso'], 'iso'),
    shutterSpeed: _nullableDouble(values['shutterSpeed'], 'shutterSpeed'),
    aperture: _nullableDouble(values['aperture'], 'aperture'),
    focalLength: _nullableDouble(values['focalLength'], 'focalLength'),
    timestamp: timestamp == null ? null : DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
    orientation: RawOrientation.values[_integer(values['orientation'], 'orientation')],
    width: _integer(values['width'], 'width'),
    height: _integer(values['height'], 'height'),
    rawWidth: _integer(values['rawWidth'], 'rawWidth'),
    rawHeight: _integer(values['rawHeight'], 'rawHeight'),
  );
}

/// Converts backend diagnostics into isolate-safe primitives.
Map<Object?, Object?> serializeBackendInfo(RawBackendInfo info) => {
  'engine': info.engine,
  'runtimeVersion': info.runtimeVersion,
  'bundledVersion': info.bundledVersion,
  'apiVersion': info.apiVersion,
};

/// Reconstructs backend diagnostics from isolate-safe primitives.
RawBackendInfo deserializeBackendInfo(Object? raw) {
  final Map<Object?, Object?> values = _map(raw, 'backend');
  return RawBackendInfo(
    engine: _string(values['engine'], 'engine'),
    runtimeVersion: _string(values['runtimeVersion'], 'runtimeVersion'),
    bundledVersion: _string(values['bundledVersion'], 'bundledVersion'),
    apiVersion: _integer(values['apiVersion'], 'apiVersion'),
  );
}

/// Converts arbitrary failures into an isolate-safe public error description.
Map<Object?, Object?> serializeRawException(Object error) {
  if (error is RawException) {
    return {
      'type': switch (error) {
        RawUnsupportedFileException() => 'RawUnsupportedFileException',
        RawIOException() => 'RawIOException',
        RawDecodeException() => 'RawDecodeException',
        RawMemoryException() => 'RawMemoryException',
        RawStateException() => 'RawStateException',
        RawCancelledException() => 'RawCancelledException',
        RawSettingsException() => 'RawSettingsException',
        RawBackendException() => 'RawBackendException',
        RawException() => 'RawException',
      },
      'message': error.message,
      'code': error.code,
    };
  }
  return {
    'type': 'RawBackendException',
    'message': 'Unexpected RAW worker failure: $error',
    'code': null,
  };
}

/// Reconstructs a stable public exception from an isolate response.
RawException deserializeRawException(Object? raw) {
  final Map<Object?, Object?> values = _map(raw, 'error');
  final String type = _string(values['type'], 'type');
  final String message = _string(values['message'], 'message');
  final int? code = _nullableInteger(values['code'], 'code');
  return switch (type) {
    'RawUnsupportedFileException' => RawUnsupportedFileException(
      message: message,
      code: code,
    ),
    'RawIOException' => RawIOException(message: message, code: code),
    'RawDecodeException' => RawDecodeException(message: message, code: code),
    'RawMemoryException' => RawMemoryException(message: message, code: code),
    'RawStateException' => RawStateException(message: message, code: code),
    'RawSettingsException' => RawSettingsException(message: message),
    'RawCancelledException' => RawCancelledException(message: message),
    _ => RawBackendException(message: message, code: code),
  };
}

Map<Object?, Object?> _map(Object? value, String name) {
  if (value is! Map<Object?, Object?>) {
    throw RawBackendException(message: 'Worker field $name is invalid.');
  }
  return value;
}

String _string(Object? value, String name) {
  if (value is! String) {
    throw RawBackendException(message: 'Worker field $name is invalid.');
  }
  return value;
}

String? _nullableString(Object? value, String name) => value == null ? null : _string(value, name);

int _integer(Object? value, String name) {
  if (value is! int) {
    throw RawBackendException(message: 'Worker field $name is invalid.');
  }
  return value;
}

int? _nullableInteger(Object? value, String name) => value == null ? null : _integer(value, name);

double _double(Object? value, String name) {
  if (value is! num) {
    throw RawBackendException(message: 'Worker field $name is invalid.');
  }
  return value.toDouble();
}

double? _nullableDouble(Object? value, String name) => value == null ? null : _double(value, name);

bool _boolean(Object? value, String name) {
  if (value is! bool) {
    throw RawBackendException(message: 'Worker field $name is invalid.');
  }
  return value;
}
