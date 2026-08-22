import 'dart:typed_data';

import 'package:rawkit/rawkit.dart';
import 'package:test/test.dart';

void main() {
  group('RawImage', () {
    test('describes an 8-bit RGB buffer', () {
      final RawImage image = RawImage.fromPixels(
        width: 2,
        height: 1,
        channels: 3,
        bitDepth: RawBitDepth.uint8,
        colorSpace: RawColorSpace.srgb,
        pixels: Uint8List.fromList([0, 1, 2, 253, 254, 255]),
      );

      expect(image.sampleCount, 6);
      expect(image.rowStride, 6);
      expect(image.byteLength, 6);
      expect(image.pixels8.last, 255);
      expect(image.toRgba8(alpha: 128), [0, 1, 2, 128, 253, 254, 255, 128]);
      expect(() => image.pixels16, throwsStateError);
    });

    test('describes a 16-bit RGB buffer', () {
      final RawImage image = RawImage.fromPixels(
        width: 1,
        height: 1,
        channels: 3,
        bitDepth: RawBitDepth.uint16,
        colorSpace: RawColorSpace.adobeRgb,
        pixels: Uint16List.fromList([0, 32768, 65535]),
      );

      expect(image.rowStride, 6);
      expect(image.byteLength, 6);
      expect(image.pixels16, [0, 32768, 65535]);
      expect(image.toRgba8(), [0, 128, 255, 255]);
      expect(() => image.pixels8, throwsStateError);
    });

    test('validates RGBA conversion inputs', () {
      final RawImage image = RawImage.fromPixels(
        width: 1,
        height: 1,
        channels: 1,
        bitDepth: RawBitDepth.uint8,
        colorSpace: RawColorSpace.srgb,
        pixels: Uint8List.fromList([42]),
      );

      expect(image.toRgba8, throwsStateError);
      expect(
        () => RawImage.fromPixels(
          width: 1,
          height: 1,
          channels: 3,
          bitDepth: RawBitDepth.uint8,
          colorSpace: RawColorSpace.srgb,
          pixels: Uint8List(3),
        ).toRgba8(alpha: 256),
        throwsRangeError,
      );
    });

    test('rejects a mismatched buffer', () {
      expect(
        () => RawImage.fromPixels(
          width: 2,
          height: 2,
          channels: 3,
          bitDepth: RawBitDepth.uint8,
          colorSpace: RawColorSpace.srgb,
          pixels: Uint8List(3),
        ),
        throwsArgumentError,
      );
    });
  });
}
