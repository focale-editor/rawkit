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
