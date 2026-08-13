import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../develop/linear_image.dart';
import '../model/raw_backend_info.dart';
import '../model/raw_develop_settings.dart';
import '../model/raw_exception.dart';
import '../model/raw_metadata.dart';
import '../model/raw_types.dart';
import 'bindings.dart';

/// Owns one native decoder handle inside the worker isolate.
final class NativeRawDocument {
  NativeRawDocument._(this._handle, this.metadata);

  ffi.Pointer<ffi.Void> _handle;

  /// Metadata copied into Dart immediately after opening.
  final RawMetadata metadata;

  /// Opens a filesystem-backed RAW document.
  static NativeRawDocument openFile(String path) {
    if (path.isEmpty) {
      throw const RawIOException(message: 'The RAW file path is empty.');
    }
    final ffi.Pointer<Utf8> nativePath = path.toNativeUtf8();
    final ffi.Pointer<ffi.Int32> error = calloc<ffi.Int32>();
    try {
      final ffi.Pointer<ffi.Void> handle = rawkitOpenFile(nativePath, error);
      if (handle == ffi.nullptr) {
        throwNativeError(error.value, operation: 'open RAW file');
      }
      try {
        return NativeRawDocument._(handle, _readMetadata(handle));
      } on Object {
        rawkitClose(handle);
        rethrow;
      }
    } finally {
      calloc.free(error);
      calloc.free(nativePath);
    }
  }

  /// Opens a memory-backed RAW document after the native shim copies its bytes.
  static NativeRawDocument openMemory(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const RawIOException(message: 'The RAW memory buffer is empty.');
    }
    final ffi.Pointer<ffi.Uint8> nativeBytes = calloc<ffi.Uint8>(bytes.length);
    final ffi.Pointer<ffi.Int32> error = calloc<ffi.Int32>();
    try {
      nativeBytes.asTypedList(bytes.length).setAll(0, bytes);
      final ffi.Pointer<ffi.Void> handle = rawkitOpenMemory(
        nativeBytes,
        bytes.length,
        error,
      );
      if (handle == ffi.nullptr) {
        throwNativeError(error.value, operation: 'open RAW memory buffer');
      }
      try {
        return NativeRawDocument._(handle, _readMetadata(handle));
      } on Object {
        rawkitClose(handle);
        rethrow;
      }
    } finally {
      calloc.free(error);
      calloc.free(nativeBytes);
    }
  }

  /// Reports the engine actually linked into the code asset.
  static RawBackendInfo backendInfo() => RawBackendInfo(
    engine: 'LibRaw',
    runtimeVersion: rawkitRuntimeVersion().toDartString(),
    bundledVersion: rawkitBundledVersion().toDartString(),
    apiVersion: rawkitApiVersion(),
  );

  /// Decodes linear 16-bit RGB samples with sensor-stage controls applied.
  LinearImage decode({
    required RawDevelopSettings settings,
    required RawColorSpace colorSpace,
    required bool halfSize,
  }) {
    _ensureOpen();
    final ffi.Pointer<NativeRawDecodeOptions> options =
        calloc<NativeRawDecodeOptions>();
    final ffi.Pointer<ffi.Pointer<NativeRawImage>> output =
        calloc<ffi.Pointer<NativeRawImage>>();
    try {
      options.ref
        ..halfSize = halfSize ? 1 : 0
        ..whiteBalance = settings.whiteBalance.index
        ..demosaicQuality = settings.demosaicQuality.index
        ..highlightRecovery = settings.highlightRecovery.index
        ..colorSpace = colorSpace.index
        ..temperature = settings.temperature
        ..tint = settings.tint;
      final int result = rawkitDecode(_handle, options, output);
      if (result != 0) {
        throwNativeError(result, operation: 'decode RAW pixels');
      }
      final ffi.Pointer<NativeRawImage> nativeImage = output.value;
      if (nativeImage == ffi.nullptr) {
        throw const RawDecodeException(
          message: 'The native decoder returned no image.',
        );
      }
      try {
        final int width = nativeImage.ref.width;
        final int height = nativeImage.ref.height;
        final int channels = nativeImage.ref.channels;
        final int bitsPerSample = nativeImage.ref.bitsPerSample;
        final int dataSize = nativeImage.ref.dataSize;
        final int sampleCount = width * height * channels;
        if (width <= 0 ||
            height <= 0 ||
            channels != 3 ||
            bitsPerSample != 16 ||
            dataSize != sampleCount * 2 ||
            nativeImage.ref.data == ffi.nullptr) {
          throw const RawDecodeException(
            message: 'The native decoder returned an invalid RGB buffer.',
          );
        }
        final Uint16List copiedPixels = Uint16List.fromList(
          nativeImage.ref.data.cast<ffi.Uint16>().asTypedList(sampleCount),
        );
        return LinearImage(
          width: width,
          height: height,
          colorSpace: colorSpace,
          pixels: copiedPixels,
        );
      } finally {
        rawkitImageFree(nativeImage);
      }
    } finally {
      calloc.free(output);
      calloc.free(options);
    }
  }

  /// Releases the native source and parser context once.
  void close() {
    final ffi.Pointer<ffi.Void> handle = _handle;
    if (handle == ffi.nullptr) {
      return;
    }
    _handle = ffi.nullptr;
    rawkitClose(handle);
  }

  void _ensureOpen() {
    if (_handle == ffi.nullptr) {
      throw const RawStateException(message: 'The RAW document is closed.');
    }
  }

  static RawMetadata _readMetadata(ffi.Pointer<ffi.Void> handle) {
    final ffi.Pointer<NativeRawMetadata> native = calloc<NativeRawMetadata>();
    try {
      final int result = rawkitGetMetadata(handle, native);
      if (result != 0) {
        throwNativeError(result, operation: 'read RAW metadata');
      }
      final NativeRawMetadata value = native.ref;
      final int timestamp = value.timestamp;
      return RawMetadata(
        cameraMake: _nullableString(value.cameraMake),
        cameraModel: _nullableString(value.cameraModel),
        normalizedCameraMake: _nullableString(value.normalizedCameraMake),
        normalizedCameraModel: _nullableString(value.normalizedCameraModel),
        lens: _nullableString(value.lens),
        lensMake: _nullableString(value.lensMake),
        iso: _positiveOrNull(value.iso),
        shutterSpeed: _positiveOrNull(value.shutterSpeed),
        aperture: _positiveOrNull(value.aperture),
        focalLength: _positiveOrNull(value.focalLength),
        timestamp: timestamp <= 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                timestamp * 1000,
                isUtc: true,
              ),
        orientation: RawOrientation.fromExifValue(value.orientation),
        width: value.width,
        height: value.height,
        rawWidth: value.rawWidth,
        rawHeight: value.rawHeight,
      );
    } finally {
      calloc.free(native);
    }
  }

  static String? _nullableString(ffi.Pointer<Utf8> pointer) {
    if (pointer == ffi.nullptr) {
      return null;
    }
    final String value = pointer.toDartString().trim();
    return value.isEmpty ? null : value;
  }

  static double? _positiveOrNull(double value) =>
      value.isFinite && value > 0 ? value : null;
}

/// Converts a native error code into a stable public exception type.
Never throwNativeError(int code, {required String operation}) {
  final String nativeMessage = rawkitErrorMessage(code).toDartString();
  final String message = 'Could not $operation: $nativeMessage.';
  switch (code) {
    case -2:
    case -8:
      throw RawUnsupportedFileException(message: message, code: code);
    case -100007:
    case -100012:
    case -100013:
    case -200002:
      throw RawMemoryException(message: message, code: code);
    case -100009:
      throw RawIOException(message: message, code: code);
    case -4:
    case -7:
    case -200004:
      throw RawStateException(message: message, code: code);
    default:
      throw RawDecodeException(message: message, code: code);
  }
}
