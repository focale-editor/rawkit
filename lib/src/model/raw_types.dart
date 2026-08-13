/// Selects the white-balance source used during RAW development.
enum RawWhiteBalance {
  /// Uses the white balance recorded by the camera.
  camera,

  /// Lets the decoder estimate a neutral white balance from the image.
  auto,

  /// Uses [RawDevelopSettings.temperature] and [RawDevelopSettings.tint].
  custom,
}

/// Selects the integer sample depth of a rendered image.
enum RawBitDepth {
  /// Produces one unsigned byte per sample.
  uint8(8),

  /// Produces one unsigned 16-bit integer per sample.
  uint16(16);

  const RawBitDepth(this.bitsPerSample);

  /// Number of bits stored for each color sample.
  final int bitsPerSample;
}

/// Selects the RGB color space of rendered samples.
enum RawColorSpace {
  /// Standard RGB with its standard piecewise transfer function.
  srgb,

  /// Adobe RGB (1998) with a 2.19921875 gamma transfer function.
  adobeRgb,

  /// ProPhoto RGB with its standard toe and 1.8 gamma transfer function.
  proPhotoRgb,
}

/// Selects the speed and quality trade-off of RAW demosaicing.
enum RawDemosaicQuality {
  /// A fast bilinear interpolation suitable for transient previews.
  fast,

  /// Adaptive homogeneity-directed interpolation for general use.
  balanced,

  /// A higher-quality interpolation for final renders.
  high,
}

/// Selects how sensor highlights are handled before tonal processing.
enum RawHighlightRecovery {
  /// Clips saturated sensor values.
  clip,

  /// Blends saturated channels with channels that still contain detail.
  blend,

  /// Attempts to reconstruct color in saturated areas.
  reconstruct,
}

/// Describes the display orientation recorded in the RAW metadata.
enum RawOrientation {
  /// No rotation is required.
  normal(1),

  /// The image should be rotated 180 degrees.
  rotate180(3),

  /// The image should be rotated 90 degrees clockwise.
  rotate90Clockwise(6),

  /// The image should be rotated 90 degrees counter-clockwise.
  rotate90CounterClockwise(8),

  /// The decoder returned an orientation that is not represented here.
  unknown(0);

  const RawOrientation(this.exifValue);

  /// Equivalent EXIF orientation value, or zero when unknown.
  final int exifValue;

  /// Converts an EXIF orientation value to a typed value.
  static RawOrientation fromExifValue(int value) => switch (value) {
    1 => normal,
    3 => rotate180,
    6 => rotate90Clockwise,
    8 => rotate90CounterClockwise,
    _ => unknown,
  };
}
