import 'package:rawkit/rawkit.dart';
import 'package:test/test.dart';

void main() {
  group('RawDevelopSettings', () {
    test('defaults are stable and neutral', () {
      const RawDevelopSettings settings = RawDevelopSettings.defaults;

      expect(settings.whiteBalance, RawWhiteBalance.camera);
      expect(settings.exposure, 0);
      expect(settings.contrast, 0);
      expect(settings.saturation, 0);
      expect(settings.demosaicQuality, RawDemosaicQuality.balanced);
      expect(settings.highlightRecovery, RawHighlightRecovery.blend);
    });

    test('copyWith changes only selected values', () {
      const RawDevelopSettings original = RawDevelopSettings.defaults;

      final RawDevelopSettings changed = original.copyWith(
        exposure: 0.7,
        highlights: -30,
        shadows: 25,
      );

      expect(changed.exposure, 0.7);
      expect(changed.highlights, -30);
      expect(changed.shadows, 25);
      expect(changed.whiteBalance, original.whiteBalance);
      expect(changed.saturation, original.saturation);
      expect(changed, isNot(original));
      expect(changed, changed.copyWith());
    });
  });
}
