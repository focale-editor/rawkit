// Hand-written bindings for RawKit's deliberately small and stable C shim.
// No LibRaw structure is represented in this file.
@ffi.DefaultAsset('package:rawkit/src/native/bindings.dart')
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// Native metadata view whose strings remain owned by the native document.
final class NativeRawMetadata extends ffi.Struct {
  /// Camera manufacturer.
  external ffi.Pointer<Utf8> cameraMake;

  /// Camera model.
  external ffi.Pointer<Utf8> cameraModel;

  /// Normalized camera manufacturer.
  external ffi.Pointer<Utf8> normalizedCameraMake;

  /// Normalized camera model.
  external ffi.Pointer<Utf8> normalizedCameraModel;

  /// Lens model.
  external ffi.Pointer<Utf8> lens;

  /// Lens manufacturer.
  external ffi.Pointer<Utf8> lensMake;

  /// ISO sensitivity.
  @ffi.Double()
  external double iso;

  /// Shutter duration in seconds.
  @ffi.Double()
  external double shutterSpeed;

  /// Aperture f-number.
  @ffi.Double()
  external double aperture;

  /// Focal length in millimetres.
  @ffi.Double()
  external double focalLength;

  /// Unix capture timestamp.
  @ffi.Int64()
  external int timestamp;

  /// EXIF-compatible orientation.
  @ffi.Int32()
  external int orientation;

  /// Visible image width.
  @ffi.Int32()
  external int width;

  /// Visible image height.
  @ffi.Int32()
  external int height;

  /// Sensor buffer width.
  @ffi.Int32()
  external int rawWidth;

  /// Sensor buffer height.
  @ffi.Int32()
  external int rawHeight;
}

/// Native decoder configuration.
final class NativeRawDecodeOptions extends ffi.Struct {
  /// Whether to decode at half width and height.
  @ffi.Int32()
  external int halfSize;

  /// White-balance enum index.
  @ffi.Int32()
  external int whiteBalance;

  /// Demosaic-quality enum index.
  @ffi.Int32()
  external int demosaicQuality;

  /// Highlight-recovery enum index.
  @ffi.Int32()
  external int highlightRecovery;

  /// Color-space enum index.
  @ffi.Int32()
  external int colorSpace;

  /// Custom temperature.
  @ffi.Double()
  external double temperature;

  /// Custom tint.
  @ffi.Double()
  external double tint;
}

/// Native decoded-image allocation.
final class NativeRawImage extends ffi.Struct {
  /// Pixel width.
  @ffi.Uint32()
  external int width;

  /// Pixel height.
  @ffi.Uint32()
  external int height;

  /// Interleaved channel count.
  @ffi.Uint32()
  external int channels;

  /// Integer sample depth.
  @ffi.Uint32()
  external int bitsPerSample;

  /// Byte length of [data].
  @ffi.Uint64()
  external int dataSize;

  /// Native-owned pixel allocation.
  external ffi.Pointer<ffi.Uint8> data;
}

@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Int32>)>(symbol: 'rawkit_open_file')
/// Opens a filesystem-backed native document.
external ffi.Pointer<ffi.Void> rawkitOpenFile(
  ffi.Pointer<Utf8> path,
  ffi.Pointer<ffi.Int32> error,
);

@ffi.Native<
  ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Uint8>,
    ffi.Size,
    ffi.Pointer<ffi.Int32>,
  )
>(symbol: 'rawkit_open_memory')
/// Opens a memory-backed native document.
external ffi.Pointer<ffi.Void> rawkitOpenMemory(
  ffi.Pointer<ffi.Uint8> data,
  int size,
  ffi.Pointer<ffi.Int32> error,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<NativeRawMetadata>)>(symbol: 'rawkit_get_metadata')
/// Copies a metadata view for an open native document.
external int rawkitGetMetadata(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<NativeRawMetadata> metadata,
);

@ffi.Native<
  ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<NativeRawDecodeOptions>,
    ffi.Pointer<ffi.Pointer<NativeRawImage>>,
  )
>(symbol: 'rawkit_decode')
/// Decodes a Dart-copyable linear RGB image.
external int rawkitDecode(
  ffi.Pointer<ffi.Void> handle,
  ffi.Pointer<NativeRawDecodeOptions> options,
  ffi.Pointer<ffi.Pointer<NativeRawImage>> image,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<NativeRawImage>)>(
  symbol: 'rawkit_image_free',
)
/// Releases an image allocation returned by [rawkitDecode].
external void rawkitImageFree(ffi.Pointer<NativeRawImage> image);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(symbol: 'rawkit_close')
/// Releases a native document handle.
external void rawkitClose(ffi.Pointer<ffi.Void> handle);

@ffi.Native<ffi.Pointer<Utf8> Function(ffi.Int32)>(
  symbol: 'rawkit_error_message',
)
/// Returns a static diagnostic string for a native error code.
external ffi.Pointer<Utf8> rawkitErrorMessage(int error);

@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'rawkit_runtime_version')
/// Returns the native engine's runtime version.
external ffi.Pointer<Utf8> rawkitRuntimeVersion();

@ffi.Native<ffi.Pointer<Utf8> Function()>(symbol: 'rawkit_bundled_version')
/// Returns the native engine version compiled into the code asset.
external ffi.Pointer<Utf8> rawkitBundledVersion();

@ffi.Native<ffi.Int32 Function()>(symbol: 'rawkit_api_version')
/// Returns the stable RawKit C shim version.
external int rawkitApiVersion();
