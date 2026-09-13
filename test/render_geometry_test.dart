import 'package:rawkit/rawkit.dart';
import 'package:rawkit/src/develop/render_geometry.dart';
import 'package:test/test.dart';

void main() {
  group('fitDimensions', () {
    test('preserves the aspect ratio without upscaling', () {
      expect(
        fitDimensions(width: 6000, height: 4000, maximumWidth: 1600, maximumHeight: 0x7fffffff),
        (width: 1600, height: 1067),
      );
      expect(
        fitDimensions(width: 300, height: 200, maximumWidth: 1600, maximumHeight: 1600),
        (width: 300, height: 200),
      );
    });
  });

  group('halfSizeCoversPreview', () {
    test('accepts bounds that fit within half resolution', () {
      expect(
        halfSizeCoversPreview(width: 6000, height: 4000, orientation: RawOrientation.normal, maximumWidth: 3000, maximumHeight: 0x7fffffff),
        isTrue,
      );
    });

    test('rejects bounds that need more than half resolution', () {
      expect(
        halfSizeCoversPreview(width: 6000, height: 4000, orientation: RawOrientation.normal, maximumWidth: 3001, maximumHeight: 0x7fffffff),
        isFalse,
      );
    });

    test('applies bounds to the displayed orientation', () {
      expect(
        halfSizeCoversPreview(width: 6000, height: 4000, orientation: RawOrientation.rotate90Clockwise, maximumWidth: 2500, maximumHeight: 0x7fffffff),
        isFalse,
      );
      expect(
        halfSizeCoversPreview(width: 6000, height: 4000, orientation: RawOrientation.rotate90Clockwise, maximumWidth: 2000, maximumHeight: 0x7fffffff),
        isTrue,
      );
    });
  });
}
