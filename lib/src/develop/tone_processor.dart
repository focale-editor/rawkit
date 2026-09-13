import 'dart:math' as math;
import 'dart:typed_data';

import 'package:rawkit/src/develop/linear_image.dart';
import 'package:rawkit/src/develop/render_geometry.dart';
import 'package:rawkit/src/develop/settings_validation.dart';
import 'package:rawkit/src/model/raw_develop_settings.dart';
import 'package:rawkit/src/model/raw_image.dart';
import 'package:rawkit/src/model/raw_types.dart';

/// Applies resolution-independent tonal controls to cached linear RGB pixels.
///
/// The luminance tone curve and the output transfer function are sampled into
/// lookup tables once per settings change, so the per-pixel work is limited to
/// table interpolation and the saturation arithmetic. Downscaled output
/// averages every covered source pixel to avoid aliasing.
abstract final class ToneProcessor {
  /// Number of intervals in each lookup table over the `[0, 1]` domain.
  static const int _tableIntervals = 1 << 16;

  /// Values below this bound are computed exactly instead of interpolated.
  ///
  /// Power curves are too steep near black for linear interpolation between
  /// the first table entries to stay within one 16-bit output code.
  static const double _exactBelow = 64 / _tableIntervals;

  /// Tone table reused while consecutive renders share tonal settings.
  static _ToneTable? _lastToneTable;

  /// Transfer-function tables indexed by [RawColorSpace.index].
  static final List<Float64List?> _encodeTables = List<Float64List?>.filled(
    RawColorSpace.values.length,
    null,
  );

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

    final ({int width, int height}) dimensions = fitDimensions(
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
    final LinearImage input = dimensions.width == source.width && dimensions.height == source.height ? source : resample(source, dimensions.width, dimensions.height);
    final _RowDeveloper developer = _RowDeveloper(
      settings: settings,
      toneTable: _toneTable(settings, source.colorSpace),
      encodeTable: _encodeTable(source.colorSpace),
      exposureMultiplier: math.pow(2, settings.exposure).toDouble() / 65535,
      output: output,
    );
    final int rowSamples = input.width * 3;
    final Uint16List encodedRow = Uint16List(rowSamples);
    for (int offset = 0; offset < sampleCount; offset += rowSamples) {
      developer.developRow(input.pixels, offset, encodedRow);
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

  /// Downscales [source] to [width] by [height] by averaging covered areas.
  ///
  /// Area averaging in linear light keeps small previews free of the aliasing
  /// that point or bilinear sampling produces. The result does not depend on
  /// tonal settings, so callers may cache it across renders.
  static LinearImage resample(LinearImage source, int width, int height) {
    if (width <= 0 || height <= 0 || width > source.width || height > source.height) {
      throw ArgumentError('Resampling only supports positive downscaled dimensions.');
    }
    final _AxisCoverage columns = _AxisCoverage(source.width, width);
    final _AxisCoverage rows = _AxisCoverage(source.height, height);
    final Uint16List pixels = source.pixels;
    final Uint16List output = Uint16List(width * height * 3);
    final Float64List row = Float64List(width * 3);
    for (int outputY = 0; outputY < height; outputY++) {
      final int rowStart = rows.starts[outputY];
      final int rowWeightStart = rows.weightStarts[outputY];
      final int rowCount = rows.weightStarts[outputY + 1] - rowWeightStart;
      row.fillRange(0, row.length, 0);
      for (int rowOffset = 0; rowOffset < rowCount; rowOffset++) {
        final double rowWeight = rows.weights[rowWeightStart + rowOffset];
        final int rowBase = (rowStart + rowOffset) * source.width;
        int outputIndex = 0;
        for (int outputX = 0; outputX < width; outputX++) {
          final int columnStart = columns.starts[outputX];
          final int columnWeightStart = columns.weightStarts[outputX];
          final int columnCount = columns.weightStarts[outputX + 1] - columnWeightStart;
          double red = 0;
          double green = 0;
          double blue = 0;
          for (int columnOffset = 0; columnOffset < columnCount; columnOffset++) {
            final double weight = columns.weights[columnWeightStart + columnOffset];
            final int sourceIndex = (rowBase + columnStart + columnOffset) * 3;
            red += pixels[sourceIndex] * weight;
            green += pixels[sourceIndex + 1] * weight;
            blue += pixels[sourceIndex + 2] * weight;
          }
          row[outputIndex] += red * rowWeight;
          row[outputIndex + 1] += green * rowWeight;
          row[outputIndex + 2] += blue * rowWeight;
          outputIndex += 3;
        }
      }
      final int outputStart = outputY * width * 3;
      for (int index = 0; index < row.length; index++) {
        output[outputStart + index] = (row[index] + 0.5).toInt();
      }
    }
    return LinearImage(
      width: width,
      height: height,
      colorSpace: source.colorSpace,
      pixels: output,
    );
  }

  /// Returns the luminance tone table for [settings], reusing the last one.
  static _ToneTable _toneTable(
    RawDevelopSettings settings,
    RawColorSpace colorSpace,
  ) {
    final _ToneTable? cached = _lastToneTable;
    if (cached != null && cached.matches(settings, colorSpace)) {
      return cached;
    }
    final _ToneTable table = _ToneTable(settings, colorSpace);
    _lastToneTable = table;
    return table;
  }

  /// Returns the sampled output transfer function of [colorSpace].
  static Float64List _encodeTable(RawColorSpace colorSpace) {
    final Float64List? cached = _encodeTables[colorSpace.index];
    if (cached != null) {
      return cached;
    }
    final Float64List table = Float64List(_tableIntervals + 2);
    for (int index = 0; index <= _tableIntervals; index++) {
      table[index] = encode(index / _tableIntervals, colorSpace);
    }
    table[_tableIntervals + 1] = table[_tableIntervals];
    _encodeTables[colorSpace.index] = table;
    return table;
  }

  /// Maps adjusted linear luminance through the regional and contrast curve.
  ///
  /// This is the exact reference function sampled by the tone lookup table.
  static double toneCurve(double luminance, RawDevelopSettings settings) {
    double target = luminance;
    target = _adjustRegion(
      target,
      settings.shadows / 100,
      1 - _smoothStep(0.05, 0.72, target),
      0.42,
    );
    target = _adjustRegion(
      target,
      settings.highlights / 100,
      _smoothStep(0.28, 0.95, target),
      0.38,
    );
    target = _adjustRegion(
      target,
      settings.whites / 100,
      _smoothStep(0.62, 1, target),
      0.3,
    );
    target = _adjustRegion(
      target,
      settings.blacks / 100,
      1 - _smoothStep(0, 0.38, target),
      0.28,
    );
    return _applyContrast(target, settings.contrast);
  }

  /// Applies the output transfer function of [colorSpace] to linear [value].
  static double encode(double value, RawColorSpace colorSpace) {
    final double linear = value.clamp(0, 1).toDouble();
    return switch (colorSpace) {
      RawColorSpace.srgb => linear <= 0.0031308 ? 12.92 * linear : 1.055 * math.pow(linear, 1 / 2.4) - 0.055,
      RawColorSpace.adobeRgb => math.pow(linear, 1 / 2.19921875).toDouble(),
      RawColorSpace.proPhotoRgb => linear <= 1 / 512 ? linear * 16 : math.pow(linear, 1 / 1.8).toDouble(),
    };
  }

  /// Returns the relative luminance weights of the linear [colorSpace] primaries.
  static ({double red, double green, double blue}) luminanceCoefficients(
    RawColorSpace colorSpace,
  ) => switch (colorSpace) {
    RawColorSpace.srgb => (red: 0.2126, green: 0.7152, blue: 0.0722),
    RawColorSpace.adobeRgb => (red: 0.2974, green: 0.6273, blue: 0.0753),
    RawColorSpace.proPhotoRgb => (red: 0.2880, green: 0.7119, blue: 0.0001),
  };

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

  static double _smoothStep(double edge0, double edge1, double value) {
    final double normalized = ((value - edge0) / (edge1 - edge0)).clamp(0, 1).toDouble();
    return normalized * normalized * (3 - 2 * normalized);
  }
}

/// Luminance tone curve sampled over adjusted luminance in `[0, 1]`.
final class _ToneTable {
  /// Samples the tone curve for [settings] in [colorSpace].
  _ToneTable(this.settings, this.colorSpace) : values = Float64List(ToneProcessor._tableIntervals + 2) {
    for (int index = 0; index <= ToneProcessor._tableIntervals; index++) {
      values[index] = ToneProcessor.toneCurve(
        index / ToneProcessor._tableIntervals,
        settings,
      );
    }
    values[ToneProcessor._tableIntervals + 1] = values[ToneProcessor._tableIntervals];
  }

  /// Settings sampled into [values].
  final RawDevelopSettings settings;

  /// Color space whose luminance weights accompany this table.
  final RawColorSpace colorSpace;

  /// Tone curve samples, padded by one entry for interpolation at `1`.
  final Float64List values;

  /// Whether this table applies to [other] settings in [otherColorSpace].
  bool matches(RawDevelopSettings other, RawColorSpace otherColorSpace) =>
      colorSpace == otherColorSpace &&
      settings.shadows == other.shadows &&
      settings.highlights == other.highlights &&
      settings.whites == other.whites &&
      settings.blacks == other.blacks &&
      settings.contrast == other.contrast;
}

/// Applies tone, saturation and output encoding to rows of linear pixels.
final class _RowDeveloper {
  /// Creates a developer that writes into [output].
  _RowDeveloper({
    required this.settings,
    required this.toneTable,
    required this.encodeTable,
    required this.exposureMultiplier,
    required TypedData output,
  }) : output8 = output is Uint8List ? output : null,
       output16 = output is Uint16List ? output : null;

  /// Settings of the render in progress.
  final RawDevelopSettings settings;

  /// Sampled luminance tone curve, possibly reused from an earlier render.
  final _ToneTable toneTable;

  /// Sampled output transfer function.
  final Float64List encodeTable;

  /// Exposure gain that also normalizes 16-bit samples to `[0, 1]`.
  final double exposureMultiplier;

  /// Eight-bit destination, when requested.
  final Uint8List? output8;

  /// Sixteen-bit destination, when requested.
  final Uint16List? output16;

  /// Develops the row of [pixels] starting at [offset] into the output.
  ///
  /// [encoded] is a scratch buffer holding exactly one row of samples. The
  /// loop body is written out in full so the compiler keeps every value
  /// unboxed; per-pixel helper calls measurably slow down large renders.
  void developRow(Uint16List pixels, int offset, Uint16List encoded) {
    const int intervals = ToneProcessor._tableIntervals;
    const double exactBelow = ToneProcessor._exactBelow;
    final RawColorSpace colorSpace = toneTable.colorSpace;
    final ({double red, double green, double blue}) weights = ToneProcessor.luminanceCoefficients(colorSpace);
    final double luminanceRed = weights.red;
    final double luminanceGreen = weights.green;
    final double luminanceBlue = weights.blue;
    final double gain = exposureMultiplier;
    final double saturation = settings.saturation / 100;
    final double vibrance = settings.vibrance / 100;
    final Float64List tone = toneTable.values;
    final Float64List encode = encodeTable;
    final double maximum = output8 != null ? 255 : 65535;

    for (int index = 0; index < encoded.length; index += 3) {
      double red = pixels[offset + index] * gain;
      double green = pixels[offset + index + 1] * gain;
      double blue = pixels[offset + index + 2] * gain;
      final double luminance = red * luminanceRed + green * luminanceGreen + blue * luminanceBlue;
      double target;
      if (luminance >= exactBelow && luminance <= 1) {
        final double position = luminance * intervals;
        final int entry = position.toInt();
        final double start = tone[entry];
        target = start + (tone[entry + 1] - start) * (position - entry);
      } else {
        target = ToneProcessor.toneCurve(luminance, settings);
      }

      if (luminance > 0.000001) {
        final double ratio = target / luminance;
        red *= ratio;
        green *= ratio;
        blue *= ratio;
      } else {
        red = target;
        green = target;
        blue = target;
      }

      final double adjustedLuminance = red * luminanceRed + green * luminanceGreen + blue * luminanceBlue;
      double channelMaximum = red > green ? red : green;
      if (blue > channelMaximum) {
        channelMaximum = blue;
      }
      double channelMinimum = red < green ? red : green;
      if (blue < channelMinimum) {
        channelMinimum = blue;
      }
      final double normalizedChroma = (channelMaximum - channelMinimum) / (channelMaximum > 0.000001 ? channelMaximum : 0.000001);
      double saturationMultiplier = 1 + saturation + (vibrance >= 0 ? vibrance * (1 - normalizedChroma) * 0.85 : vibrance * 0.85);
      if (saturationMultiplier < 0) {
        saturationMultiplier = 0;
      }
      encoded[index] = _encodeChannel(encode, adjustedLuminance + (red - adjustedLuminance) * saturationMultiplier, colorSpace, maximum);
      encoded[index + 1] = _encodeChannel(encode, adjustedLuminance + (green - adjustedLuminance) * saturationMultiplier, colorSpace, maximum);
      encoded[index + 2] = _encodeChannel(encode, adjustedLuminance + (blue - adjustedLuminance) * saturationMultiplier, colorSpace, maximum);
    }

    final Uint16List? destination16 = output16;
    if (destination16 != null) {
      destination16.setRange(offset, offset + encoded.length, encoded);
    } else {
      output8?.setRange(offset, offset + encoded.length, encoded);
    }
  }

  /// Clamps, encodes and rounds one linear channel to `[0, maximum]`.
  @pragma('vm:prefer-inline')
  static int _encodeChannel(
    Float64List table,
    double linear,
    RawColorSpace colorSpace,
    double maximum,
  ) {
    final double clamped = linear < 0 ? 0 : (linear > 1 ? 1 : linear);
    if (clamped < ToneProcessor._exactBelow) {
      return (ToneProcessor.encode(clamped, colorSpace) * maximum + 0.5).toInt();
    }
    final double position = clamped * ToneProcessor._tableIntervals;
    final int entry = position.toInt();
    final double start = table[entry];
    return ((start + (table[entry + 1] - start) * (position - entry)) * maximum + 0.5).toInt();
  }
}

/// Source spans and area weights covering each output sample along one axis.
final class _AxisCoverage {
  /// Computes box-filter coverage for resampling [sourceLength] samples.
  factory _AxisCoverage(int sourceLength, int outputLength) {
    final Int32List starts = Int32List(outputLength);
    final Int32List weightStarts = Int32List(outputLength + 1);
    final List<double> weights = <double>[];
    final double scale = sourceLength / outputLength;
    for (int output = 0; output < outputLength; output++) {
      final double spanStart = output * scale;
      final double spanEnd = math.min((output + 1) * scale, sourceLength.toDouble());
      final int first = spanStart.floor();
      final int last = math.min(spanEnd.ceil(), sourceLength) - 1;
      starts[output] = first;
      weightStarts[output] = weights.length;
      final double spanLength = spanEnd - spanStart;
      for (int source = first; source <= last; source++) {
        final double overlap = math.min(spanEnd, source + 1) - math.max(spanStart, source.toDouble());
        weights.add(overlap / spanLength);
      }
    }
    weightStarts[outputLength] = weights.length;
    return _AxisCoverage._(starts, weightStarts, Float64List.fromList(weights));
  }

  _AxisCoverage._(this.starts, this.weightStarts, this.weights);

  /// First source index covered by each output sample.
  final Int32List starts;

  /// Offsets into [weights] for each output sample, with a trailing end offset.
  final Int32List weightStarts;

  /// Normalized source weights for all output samples.
  final Float64List weights;
}
