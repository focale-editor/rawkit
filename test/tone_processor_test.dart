import 'dart:math' as math;
import 'dart:typed_data';

import 'package:rawkit/rawkit.dart';
import 'package:rawkit/src/develop/linear_image.dart';
import 'package:rawkit/src/develop/tone_processor.dart';
import 'package:test/test.dart';

void main() {
  group('ToneProcessor', () {
    late LinearImage source;

    setUp(() {
      source = LinearImage(
        width: 2,
        height: 2,
        colorSpace: RawColorSpace.srgb,
        pixels: Uint16List.fromList([
          4096,
          8192,
          16384,
          12000,
          18000,
          24000,
          28000,
          32000,
          36000,
          48000,
          52000,
          56000,
        ]),
      );
    });

    test('renders expected dimensions and sample depth', () {
      final RawImage image = ToneProcessor.render(
        source: source,
        settings: RawDevelopSettings.defaults,
        bitDepth: RawBitDepth.uint16,
        maximumWidth: 1,
        maximumHeight: 1,
      );

      expect(image.width, 1);
      expect(image.height, 1);
      expect(image.channels, 3);
      expect(image.pixels16.length, 3);
    });

    test('positive exposure raises a midtone', () {
      final RawImage neutral = ToneProcessor.render(
        source: source,
        settings: RawDevelopSettings.defaults,
        bitDepth: RawBitDepth.uint16,
        maximumWidth: 2,
        maximumHeight: 2,
      );
      final RawImage raised = ToneProcessor.render(
        source: source,
        settings: RawDevelopSettings.defaults.copyWith(exposure: 1),
        bitDepth: RawBitDepth.uint16,
        maximumWidth: 2,
        maximumHeight: 2,
      );

      expect(raised.pixels16[4], greaterThan(neutral.pixels16[4]));
    });

    test('minus 100 saturation produces neutral RGB pixels', () {
      final RawImage image = ToneProcessor.render(
        source: source,
        settings: RawDevelopSettings.defaults.copyWith(saturation: -100),
        bitDepth: RawBitDepth.uint16,
        maximumWidth: 2,
        maximumHeight: 2,
      );

      for (int index = 0; index < image.sampleCount; index += 3) {
        expect(image.pixels16[index], image.pixels16[index + 1]);
        expect(image.pixels16[index + 1], image.pixels16[index + 2]);
      }
    });

    test('combined desaturation controls never invert colors', () {
      final RawImage image = ToneProcessor.render(
        source: source,
        settings: RawDevelopSettings.defaults.copyWith(
          saturation: -100,
          vibrance: -100,
        ),
        bitDepth: RawBitDepth.uint16,
        maximumWidth: 2,
        maximumHeight: 2,
      );

      for (int index = 0; index < image.sampleCount; index += 3) {
        expect(image.pixels16[index], image.pixels16[index + 1]);
        expect(image.pixels16[index + 1], image.pixels16[index + 2]);
      }
    });

    test('downscaling averages the covered source area', () {
      final LinearImage wide = LinearImage(
        width: 3,
        height: 1,
        colorSpace: RawColorSpace.srgb,
        pixels: Uint16List.fromList([300, 300, 300, 600, 600, 600, 900, 900, 900]),
      );

      final LinearImage resampled = ToneProcessor.resample(wide, 2, 1);

      // Each output pixel covers 1.5 source pixels.
      expect(resampled.pixels, [400, 400, 400, 800, 800, 800]);
      expect(ToneProcessor.resample(source, 1, 1).pixels, [23024, 27548, 33096]);
    });

    test('lookup tables match the exact tone and transfer functions', () {
      final math.Random random = math.Random(42);
      final Uint16List pixels = Uint16List(3000);
      for (int index = 0; index < pixels.length; index++) {
        pixels[index] = switch (index % 3) {
          0 => random.nextInt(80),
          1 => random.nextInt(4096),
          _ => random.nextInt(65536),
        };
      }
      final List<RawDevelopSettings> settingsList = [
        RawDevelopSettings.defaults.copyWith(contrast: -100, shadows: 100, vibrance: 60),
        RawDevelopSettings.defaults.copyWith(contrast: 100, blacks: -100, whites: 100, saturation: -40),
        RawDevelopSettings.defaults.copyWith(exposure: 4, highlights: -100, vibrance: -50),
      ];

      for (final RawColorSpace colorSpace in RawColorSpace.values) {
        final LinearImage image = LinearImage(width: 1000, height: 1, colorSpace: colorSpace, pixels: pixels);
        for (final RawDevelopSettings settings in settingsList) {
          final Uint16List developed = ToneProcessor.render(
            source: image,
            settings: settings,
            bitDepth: RawBitDepth.uint16,
            maximumWidth: 1000,
            maximumHeight: 1,
          ).pixels16;
          for (int index = 0; index < pixels.length; index += 3) {
            final List<int> expected = _referencePixel(pixels, index, settings, colorSpace);
            for (int channel = 0; channel < 3; channel++) {
              expect((developed[index + channel] - expected[channel]).abs(), lessThanOrEqualTo(1), reason: '$colorSpace $settings pixel $index');
            }
          }
        }
      }
    });

    test('invalid dimensions are rejected', () {
      expect(
        () => ToneProcessor.render(
          source: source,
          settings: RawDevelopSettings.defaults,
          bitDepth: RawBitDepth.uint8,
          maximumWidth: 0,
          maximumHeight: 10,
        ),
        throwsArgumentError,
      );
    });
  });
}

/// Develops one pixel with the exact, table-free reference formulas.
List<int> _referencePixel(
  Uint16List pixels,
  int index,
  RawDevelopSettings settings,
  RawColorSpace colorSpace,
) {
  final ({double red, double green, double blue}) weights = ToneProcessor.luminanceCoefficients(colorSpace);
  final double gain = math.pow(2, settings.exposure) / 65535;
  double red = pixels[index] * gain;
  double green = pixels[index + 1] * gain;
  double blue = pixels[index + 2] * gain;
  final double luminance = red * weights.red + green * weights.green + blue * weights.blue;
  final double target = ToneProcessor.toneCurve(luminance, settings);
  if (luminance > 0.000001) {
    red *= target / luminance;
    green *= target / luminance;
    blue *= target / luminance;
  } else {
    red = target;
    green = target;
    blue = target;
  }
  final double adjusted = red * weights.red + green * weights.green + blue * weights.blue;
  final double maximum = math.max(red, math.max(green, blue));
  final double minimum = math.min(red, math.min(green, blue));
  final double chroma = (maximum - minimum) / math.max(maximum, 0.000001);
  final double vibrance = settings.vibrance / 100;
  final double multiplier = math.max(0, 1 + settings.saturation / 100 + (vibrance >= 0 ? vibrance * (1 - chroma) * 0.85 : vibrance * 0.85));
  return [
    for (final double value in [red, green, blue]) (ToneProcessor.encode(adjusted + (value - adjusted) * multiplier, colorSpace) * 65535).round(),
  ];
}
