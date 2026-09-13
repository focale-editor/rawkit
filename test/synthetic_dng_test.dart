import 'package:rawkit/rawkit.dart';
import 'package:test/test.dart';

import 'support/synthetic_dng.dart';

void main() {
  final DateTime capturedAt = DateTime.utc(2021, 7, 14, 9, 30, 15);
  late RawDocument document;

  setUp(() async {
    document = await RawDocument.openMemory(
      buildSyntheticDng(
        width: 64,
        height: 48,
        orientation: 6,
        capturedAt: capturedAt,
      ),
    );
  });

  tearDown(() => document.close());

  test('reports the recorded wall-clock time regardless of the host zone', () {
    expect(document.metadata.timestamp, capturedAt);
    expect(document.metadata.cameraMake, 'RawKit');
  });

  test('applies the recorded orientation to rendered pixels', () async {
    expect(document.metadata.orientation, RawOrientation.rotate90Clockwise);
    expect(document.metadata.width, 64);
    expect(document.metadata.height, 48);

    final RawImage image = await document.render(RawDevelopSettings.defaults);

    expect(image.width, 48);
    expect(image.height, 64);
  });

  test('previews use a full decode when half size is too small', () async {
    final RawImage small = await document.renderPreview(
      RawDevelopSettings.defaults,
      maxWidth: 16,
    );
    final RawImage large = await document.renderPreview(
      RawDevelopSettings.defaults,
      maxWidth: 40,
    );

    expect(small.width, 16);
    expect(large.width, 40);
    expect(large.height, 53);
  });

  test('superseded previews are cancelled and the newest one renders', () async {
    final List<Object> outcomes = await Future.wait([
      for (int index = 0; index < 4; index++)
        document
            .renderPreview(
              RawDevelopSettings.defaults.copyWith(exposure: index / 4),
              maxWidth: 32,
            )
            .then<Object>((image) => image, onError: (Object error) => error),
    ]);

    expect(outcomes[0], isA<RawImage>());
    expect(outcomes[1], isA<RawCancelledException>());
    expect(outcomes[2], isA<RawCancelledException>());
    expect(outcomes[3], isA<RawImage>());
  });
}
