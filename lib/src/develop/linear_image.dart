import 'dart:typed_data';

import 'package:rawkit/src/model/raw_types.dart';

/// Dart-owned linear RGB buffer produced by the native decoder.
final class LinearImage {
  /// Creates a validated linear RGB image.
  LinearImage({
    required this.width,
    required this.height,
    required this.colorSpace,
    required this.pixels,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('Linear image dimensions must be positive.');
    }
    if (pixels.length != width * height * 3) {
      throw ArgumentError(
        'A linear image must contain interleaved RGB samples.',
      );
    }
  }

  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Primaries used by the linear samples.
  final RawColorSpace colorSpace;

  /// Interleaved, linear, 16-bit RGB samples.
  final Uint16List pixels;
}
