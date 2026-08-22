import 'dart:typed_data';

import 'package:rawkit/src/model/raw_types.dart';

/// An interleaved RGB image whose pixel buffer is owned by Dart.
///
/// No native allocation is retained after construction. [pixels] is mutable so
/// callers can pass or transform it without another mandatory copy.
final class RawImage {
  /// Creates an image from an interleaved Dart-owned sample buffer.
  ///
  /// The buffer must contain exactly `width * height * channels` samples and
  /// must match [bitDepth]. RawKit renders three-channel RGB images, while this
  /// constructor also permits other positive channel counts for interoperability.
  RawImage.fromPixels({
    required this.width,
    required this.height,
    required this.channels,
    required this.bitDepth,
    required this.colorSpace,
    required TypedData pixels,
  }) : _pixels = pixels {
    if (width <= 0 || height <= 0 || channels <= 0) {
      throw ArgumentError(
        'Image dimensions and channel count must be positive.',
      );
    }
    final bool hasExpectedType = switch (bitDepth) {
      RawBitDepth.uint8 => pixels is Uint8List,
      RawBitDepth.uint16 => pixels is Uint16List,
    };
    if (!hasExpectedType) {
      throw ArgumentError('Pixel buffer type does not match $bitDepth.');
    }
    if (pixels.lengthInBytes != expectedByteLength) {
      throw ArgumentError.value(
        pixels.lengthInBytes,
        'pixels',
        'Expected $expectedByteLength bytes for ${width}x$height with '
            '$channels channels at ${bitDepth.bitsPerSample} bits.',
      );
    }
  }

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Number of interleaved color channels per pixel.
  final int channels;

  /// Integer sample depth.
  final RawBitDepth bitDepth;

  /// RGB color space and transfer function of the samples.
  final RawColorSpace colorSpace;

  final TypedData _pixels;

  /// Interleaved samples as either [Uint8List] or [Uint16List].
  TypedData get pixels => _pixels;

  /// Eight-bit samples.
  ///
  /// Throws [StateError] when [bitDepth] is not [RawBitDepth.uint8].
  Uint8List get pixels8 {
    final TypedData value = _pixels;
    if (value is! Uint8List) {
      throw StateError('This image contains 16-bit samples.');
    }
    return value;
  }

  /// Sixteen-bit samples in host byte order.
  ///
  /// Throws [StateError] when [bitDepth] is not [RawBitDepth.uint16].
  Uint16List get pixels16 {
    final TypedData value = _pixels;
    if (value is! Uint16List) {
      throw StateError('This image contains 8-bit samples.');
    }
    return value;
  }

  /// Byte view over the same sample storage, without copying.
  Uint8List get bytes => _pixels.buffer.asUint8List(_pixels.offsetInBytes, _pixels.lengthInBytes);

  /// Number of samples in the interleaved pixel buffer.
  int get sampleCount => width * height * channels;

  /// Number of bytes in one image row.
  int get rowStride => width * channels * (bitDepth.bitsPerSample ~/ 8);

  /// Expected buffer size for the image description.
  int get expectedByteLength => width * height * channels * (bitDepth.bitsPerSample ~/ 8);

  /// Actual byte length of [pixels].
  int get byteLength => _pixels.lengthInBytes;

  /// Copies this RGB image into a tightly packed 8-bit RGBA buffer.
  ///
  /// This is a convenience bridge for clients such as Flutter image engines,
  /// which commonly consume `rgba8888`. Sixteen-bit samples are rounded to
  /// eight bits; color values are otherwise unchanged, so callers should
  /// request the color space expected by the destination before rendering.
  ///
  /// RawKit renders three-channel images. A [StateError] is thrown if this
  /// instance has another channel count. [alpha] must be between 0 and 255.
  Uint8List toRgba8({int alpha = 255}) {
    RangeError.checkValueInInterval(alpha, 0, 255, 'alpha');
    if (channels != 3) {
      throw StateError('RGBA conversion requires a three-channel RGB image.');
    }

    final Uint8List result = Uint8List(width * height * 4);
    final TypedData source = _pixels;
    if (source is Uint8List) {
      for (int sourceOffset = 0, targetOffset = 0; sourceOffset < source.length; sourceOffset += 3, targetOffset += 4) {
        result[targetOffset] = source[sourceOffset];
        result[targetOffset + 1] = source[sourceOffset + 1];
        result[targetOffset + 2] = source[sourceOffset + 2];
        result[targetOffset + 3] = alpha;
      }
    } else if (source is Uint16List) {
      for (int sourceOffset = 0, targetOffset = 0; sourceOffset < source.length; sourceOffset += 3, targetOffset += 4) {
        result[targetOffset] = (source[sourceOffset] + 128) ~/ 257;
        result[targetOffset + 1] = (source[sourceOffset + 1] + 128) ~/ 257;
        result[targetOffset + 2] = (source[sourceOffset + 2] + 128) ~/ 257;
        result[targetOffset + 3] = alpha;
      }
    }
    return result;
  }

  @override
  String toString() =>
      'RawImage(${width}x$height, $channels channels, '
      '${bitDepth.bitsPerSample}-bit, $colorSpace)';
}
