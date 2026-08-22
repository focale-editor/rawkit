import 'dart:math' as math;
import 'dart:typed_data';

import 'package:rawkit/src/develop/linear_image.dart';
import 'package:rawkit/src/develop/settings_validation.dart';
import 'package:rawkit/src/model/raw_develop_settings.dart';
import 'package:rawkit/src/model/raw_image.dart';
import 'package:rawkit/src/model/raw_types.dart';

/// Applies resolution-independent tonal controls to cached linear RGB pixels.
abstract final class ToneProcessor {
  /// Develops [source] and converts it to a Dart-owned output image.
  static RawImage render({
    required LinearImage source,
    required RawDevelopSettings settings,
    required RawBitDepth bitDepth,
    required int maximumWidth,
    required int maximumHeight,
  }) {
    validateDevelopSettings(settings);
    if (maximumWidth <= 0 || maximumHeight <= 0) {
      throw ArgumentError('Maximum render dimensions must be positive.');
    }

    final ({int width, int height}) dimensions = _fitDimensions(
      width: source.width,
      height: source.height,
      maximumWidth: maximumWidth,
      maximumHeight: maximumHeight,
    );
    final int sampleCount = dimensions.width * dimensions.height * 3;
    final TypedData output = switch (bitDepth) {
      RawBitDepth.uint8 => Uint8List(sampleCount),
      RawBitDepth.uint16 => Uint16List(sampleCount),
    };
    final ({double red, double green, double blue}) luminance = _luminanceCoefficients(source.colorSpace);
    final double exposureMultiplier = math.pow(2, settings.exposure).toDouble();

    int outputIndex = 0;
    for (int y = 0; y < dimensions.height; y++) {
      final double sourceY = dimensions.height == 1 ? 0 : y * (source.height - 1) / (dimensions.height - 1);
      for (int x = 0; x < dimensions.width; x++) {
        final double sourceX = dimensions.width == 1 ? 0 : x * (source.width - 1) / (dimensions.width - 1);
        final ({double red, double green, double blue}) sampled = _sampleBilinear(source, sourceX, sourceY);
        final ({double red, double green, double blue}) developed = _developPixel(
          red: sampled.red * exposureMultiplier,
          green: sampled.green * exposureMultiplier,
          blue: sampled.blue * exposureMultiplier,
          luminance: luminance,
          settings: settings,
        );
        final double encodedRed = _encode(developed.red, source.colorSpace);
        final double encodedGreen = _encode(developed.green, source.colorSpace);
        final double encodedBlue = _encode(developed.blue, source.colorSpace);

        switch (output) {
          case final Uint8List pixels:
            pixels[outputIndex++] = _quantize(encodedRed, 255);
            pixels[outputIndex++] = _quantize(encodedGreen, 255);
            pixels[outputIndex++] = _quantize(encodedBlue, 255);
          case final Uint16List pixels:
            pixels[outputIndex++] = _quantize(encodedRed, 65535);
            pixels[outputIndex++] = _quantize(encodedGreen, 65535);
            pixels[outputIndex++] = _quantize(encodedBlue, 65535);
          default:
            throw StateError('Unsupported output buffer type.');
        }
      }
    }

    return RawImage.fromPixels(
      width: dimensions.width,
      height: dimensions.height,
      channels: 3,
      bitDepth: bitDepth,
      colorSpace: source.colorSpace,
      pixels: output,
    );
  }

  static ({int width, int height}) _fitDimensions({
    required int width,
    required int height,
    required int maximumWidth,
    required int maximumHeight,
  }) {
    final double scale = math.min(
      1,
      math.min(maximumWidth / width, maximumHeight / height),
    );
    return (
      width: math.max(1, (width * scale).round()),
      height: math.max(1, (height * scale).round()),
    );
  }

  static ({double red, double green, double blue}) _sampleBilinear(
    LinearImage source,
    double x,
    double y,
  ) {
    final int left = x.floor();
    final int top = y.floor();
    final int right = math.min(left + 1, source.width - 1);
    final int bottom = math.min(top + 1, source.height - 1);
    final double horizontal = x - left;
    final double vertical = y - top;
    final int topLeft = (top * source.width + left) * 3;
    final int topRight = (top * source.width + right) * 3;
    final int bottomLeft = (bottom * source.width + left) * 3;
    final int bottomRight = (bottom * source.width + right) * 3;
    final Uint16List pixels = source.pixels;

    double channel(int offset) {
      final double upper = _mix(
        pixels[topLeft + offset].toDouble(),
        pixels[topRight + offset].toDouble(),
        horizontal,
      );
      final double lower = _mix(
        pixels[bottomLeft + offset].toDouble(),
        pixels[bottomRight + offset].toDouble(),
        horizontal,
      );
      return _mix(upper, lower, vertical) / 65535;
    }

    return (red: channel(0), green: channel(1), blue: channel(2));
  }

  static ({double red, double green, double blue}) _developPixel({
    required double red,
    required double green,
    required double blue,
    required ({double red, double green, double blue}) luminance,
    required RawDevelopSettings settings,
  }) {
    double currentRed = red;
    double currentGreen = green;
    double currentBlue = blue;
    double currentLuminance = currentRed * luminance.red + currentGreen * luminance.green + currentBlue * luminance.blue;
    double targetLuminance = currentLuminance;

    targetLuminance = _adjustRegion(
      targetLuminance,
      settings.shadows / 100,
      1 - _smoothStep(0.05, 0.72, targetLuminance),
      0.42,
    );
    targetLuminance = _adjustRegion(
      targetLuminance,
      settings.highlights / 100,
      _smoothStep(0.28, 0.95, targetLuminance),
      0.38,
    );
    targetLuminance = _adjustRegion(
      targetLuminance,
      settings.whites / 100,
      _smoothStep(0.62, 1, targetLuminance),
      0.3,
    );
    targetLuminance = _adjustRegion(
      targetLuminance,
      settings.blacks / 100,
      1 - _smoothStep(0, 0.38, targetLuminance),
      0.28,
    );
    targetLuminance = _applyContrast(targetLuminance, settings.contrast);

    if (currentLuminance > 0.000001) {
      final double luminanceRatio = targetLuminance / currentLuminance;
      currentRed *= luminanceRatio;
      currentGreen *= luminanceRatio;
      currentBlue *= luminanceRatio;
    } else {
      currentRed = targetLuminance;
      currentGreen = targetLuminance;
      currentBlue = targetLuminance;
    }

    currentLuminance = currentRed * luminance.red + currentGreen * luminance.green + currentBlue * luminance.blue;
    final double maximum = math.max(currentRed, math.max(currentGreen, currentBlue));
    final double minimum = math.min(currentRed, math.min(currentGreen, currentBlue));
    final double chroma = maximum - minimum;
    final double normalizedChroma = chroma / math.max(maximum, 0.000001);
    double saturationMultiplier = 1 + settings.saturation / 100;
    final double vibrance = settings.vibrance / 100;
    saturationMultiplier += vibrance >= 0 ? vibrance * (1 - normalizedChroma) * 0.85 : vibrance * 0.85;
    saturationMultiplier = math.max(0, saturationMultiplier);

    currentRed = currentLuminance + (currentRed - currentLuminance) * saturationMultiplier;
    currentGreen = currentLuminance + (currentGreen - currentLuminance) * saturationMultiplier;
    currentBlue = currentLuminance + (currentBlue - currentLuminance) * saturationMultiplier;
    return (
      red: currentRed.clamp(0, 1).toDouble(),
      green: currentGreen.clamp(0, 1).toDouble(),
      blue: currentBlue.clamp(0, 1).toDouble(),
    );
  }

  static double _adjustRegion(
    double luminance,
    double amount,
    double weight,
    double strength,
  ) {
    final double scaledAmount = amount * weight * strength;
    if (scaledAmount >= 0) {
      return luminance + (1 - luminance) * scaledAmount;
    }
    return luminance + luminance * scaledAmount;
  }

  static double _applyContrast(double luminance, double contrast) {
    final double clampedLuminance = luminance.clamp(0, 1).toDouble();
    if (contrast == 0) {
      return clampedLuminance;
    }
    const double pivot = 0.18;
    final double exponent = contrast >= 0 ? 1 + contrast / 50 : 1 / (1 - contrast / 50);
    if (clampedLuminance <= pivot) {
      return pivot * math.pow(clampedLuminance / pivot, exponent);
    }
    return 1 - (1 - pivot) * math.pow((1 - clampedLuminance) / (1 - pivot), exponent);
  }

  static double _encode(double linear, RawColorSpace colorSpace) {
    final double value = linear.clamp(0, 1).toDouble();
    return switch (colorSpace) {
      RawColorSpace.srgb => value <= 0.0031308 ? 12.92 * value : 1.055 * math.pow(value, 1 / 2.4) - 0.055,
      RawColorSpace.adobeRgb => math.pow(value, 1 / 2.19921875).toDouble(),
      RawColorSpace.proPhotoRgb => value <= 1 / 512 ? value * 16 : math.pow(value, 1 / 1.8).toDouble(),
    };
  }

  static ({double red, double green, double blue}) _luminanceCoefficients(
    RawColorSpace colorSpace,
  ) => switch (colorSpace) {
    RawColorSpace.srgb => (red: 0.2126, green: 0.7152, blue: 0.0722),
    RawColorSpace.adobeRgb => (red: 0.2974, green: 0.6273, blue: 0.0753),
    RawColorSpace.proPhotoRgb => (red: 0.2880, green: 0.7119, blue: 0.0001),
  };

  static double _smoothStep(double edge0, double edge1, double value) {
    final double normalized = ((value - edge0) / (edge1 - edge0)).clamp(0, 1).toDouble();
    return normalized * normalized * (3 - 2 * normalized);
  }

  static double _mix(double start, double end, double amount) => start + (end - start) * amount;

  static int _quantize(double value, int maximum) => (value.clamp(0, 1) * maximum).round();
}
