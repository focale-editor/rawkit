import 'dart:typed_data';

import 'package:rawkit/rawkit.dart';
import 'package:test/test.dart';

import 'support/synthetic_dcp.dart';
import 'support/synthetic_dng.dart';

void main() {
  test('reads either byte order and owns immutable identity bytes', () {
    for (final Endian endian in [Endian.little, Endian.big]) {
      final Uint8List bytes = buildSyntheticDcp(endian: endian);
      final RawCameraProfile profile = RawCameraProfile.fromBytes(bytes);
      expect(profile.name, 'Synthetic profile');
      expect(profile.cameraModel, 'RawKit Synthetic');
      expect(profile, RawCameraProfile.fromBytes(bytes));
      bytes[0] = 0;
      expect(profile.bytes[0], endian == Endian.little ? 73 : 77);
      expect(() => profile.bytes[0] = 0, throwsUnsupportedError);
    }
  });
  test('rejects malformed directories and absent colour matrices', () {
    expect(() => RawCameraProfile.fromBytes(Uint8List(9)), throwsFormatException);
    final Uint8List bytes = buildSyntheticDcp();
    ByteData.sublistView(bytes).setUint32(4, 0xffffffff, Endian.little);
    expect(() => RawCameraProfile.fromBytes(bytes), throwsFormatException);
  });
  group('camera-native rendering', () {
    late RawDocument document;
    setUp(() async {
      document = await RawDocument.openMemory(buildSyntheticDng(width: 64, height: 48, orientation: 1, capturedAt: DateTime.utc(2020)));
    });
    tearDown(() => document.close());
    test('applies forward matrices, exposure, switches and clears cached profiles', () async {
      final RawDevelopSettings settings = RawDevelopSettings.defaults.copyWith(cameraProfile: RawCameraProfile.fromBytes(buildSyntheticDcp()));
      final RawImage plain = await document.render(RawDevelopSettings.defaults);
      final RawImage first = await document.render(settings);
      final RawImage bright = await document.render(settings.copyWith(cameraProfile: RawCameraProfile.fromBytes(buildSyntheticDcp(exposure: 1))));
      final RawImage restored = await document.render(settings.copyWith(clearCameraProfile: true));
      expect(first.bytes, isNot(equals(plain.bytes)));
      expect(bright.bytes, isNot(equals(first.bytes)));
      expect(restored.bytes, orderedEquals(plain.bytes));
    });
    test('rejects a different camera and unsupported or singular transforms', () async {
      for (final Uint8List bytes in [
        buildSyntheticDcp(camera: 'Another Camera'),
        buildSyntheticDcp(
          fields: {
            50721: [0, 0, 0, 0, 0, 0, 0, 0, 0],
          },
        ),
        buildSyntheticDcp(
          fields: {
            52529: [21],
          },
        ),
        buildSyntheticDcp(
          fields: {
            50940: [0, 0, .5, double.nan, 1, 1],
          },
        ),
      ]) {
        await expectLater(document.render(RawDevelopSettings.defaults.copyWith(cameraProfile: RawCameraProfile.fromBytes(bytes))), throwsA(isA<RawDecodeException>()));
      }
      expect((await document.render(RawDevelopSettings.defaults)).width, 64);
    });
    test('accepts dense real-world tone curves without relaxing the byte budget', () async {
      final List<double> curve = [
        for (int i = 0; i < 8192; i++) ...[i / 8191, i / 8191],
      ];
      final RawCameraProfile profile = RawCameraProfile.fromBytes(buildSyntheticDcp(fields: {50940: curve}));
      expect((await document.render(RawDevelopSettings.defaults.copyWith(cameraProfile: profile))).width, 64);
    });
    test('matrix-only, dual illuminants, tables and curves render in both byte orders', () async {
      for (final Endian endian in [Endian.little, Endian.big]) {
        final RawCameraProfile profile = RawCameraProfile.fromBytes(
          buildSyntheticDcp(
            endian: endian,
            forward: false,
            fields: {
              50722: [1, 0, 0, 0, 1, 0, 0, 0, 1],
              50779: [17],
              50937: [1, 2, 1],
              50938: [0, 1, 1, 20, .8, 1],
              50939: [0, 1, 1, -20, 1.2, 1],
              50981: [1, 2, 1],
              50982: [0, 1, 1, 0, .9, 1],
              50940: [0, 0, .5, .6, 1, 1],
            },
          ),
        );
        final RawImage image = await document.render(RawDevelopSettings.defaults.copyWith(cameraProfile: profile));
        expect(image.width, 64);
        expect(image.bytes.any((value) => value > 0), isTrue);
      }
    });
  });
}
