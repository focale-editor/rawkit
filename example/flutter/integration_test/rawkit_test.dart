import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rawkit_flutter_example/main.dart' as example;

import '../../../test/native_smoke_test.dart' as native;
import '../../../test/preview_scheduler_test.dart' as scheduler;
import '../../../test/raw_develop_settings_test.dart' as settings;
import '../../../test/raw_document_error_test.dart' as errors;
import '../../../test/raw_image_test.dart' as images;
import '../../../test/render_geometry_test.dart' as geometry;
import '../../../test/synthetic_dng_test.dart' as synthetic;
import '../../../test/tone_processor_test.dart' as tone;
import '../../rawkit_example.dart' as cli;

/// Runs the existing runtime suites inside the native Flutter application.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('native backend', native.main);
  group('preview scheduler', scheduler.main);
  group('development settings', settings.main);
  group('document errors', errors.main);
  group('image buffers', images.main);
  group('render geometry', geometry.main);
  group('synthetic DNG', synthetic.main);
  group('tone processing', tone.main);

  test(
    'CLI opens a sandbox file and writes eight- and sixteen-bit images',
    () async {
      final Directory temporaryDirectory = await Directory.systemTemp.createTemp('rawkit-ios-');
      try {
        final ByteData asset = await rootBundle.load('assets/sample.dng');
        final File source = File('${temporaryDirectory.path}/sample.dng');
        await source.writeAsBytes(
          asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
        );
        final String output = '${temporaryDirectory.path}/developed.ppm';
        await cli.main([source.path, output]);
        expect(await File(output).length(), 15 + 64 * 48 * 3 * 2);
        expect(await File('$output.preview.ppm').length(), 13 + 64 * 48 * 3);
      } finally {
        await temporaryDirectory.delete(recursive: true);
      }
    },
  );

  testWidgets('example displays the developed native RAW preview', (
    tester,
  ) async {
    example.main();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('RawKit native example'), findsOneWidget);
    expect(find.text('64 × 48 · 16-bit RGB'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
