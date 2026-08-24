@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../tool/library_preparer.dart';
import '../tool/web_library_builder.dart';

void main() {
  group('LibraryPreparationOptions', () {
    test('defaults to preparing every target', () {
      final LibraryPreparationOptions options = LibraryPreparationOptions.parse(const <String>[]);

      expect(options.target, LibraryPreparationTarget.all);
      expect(options.force, isFalse);
      expect(options.webOutput, isNull);
    });

    test('parses a Web target with replacement and output options', () {
      final LibraryPreparationOptions options = LibraryPreparationOptions.parse(const <String>[
        'web',
        '--force',
        '--output=prepared',
      ]);

      expect(options.target, LibraryPreparationTarget.web);
      expect(options.force, isTrue);
      expect(options.webOutput, 'prepared');
    });

    test('rejects a Web output for a desktop-only preparation', () {
      expect(
        () => LibraryPreparationOptions.parse(const <String>[
          'desktop',
          '--output=prepared',
        ]),
        throwsFormatException,
      );
    });
  });

  test('copies published Web artifacts into a plain Dart project', () async {
    final Directory temporary = await Directory.systemTemp.createTemp(
      'rawkit-preparer-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final Directory packageRoot = Directory('${temporary.path}/package');
    final Directory projectRoot = Directory('${temporary.path}/application');
    final Directory assets = Directory('${packageRoot.path}/assets/web');
    await assets.create(recursive: true);
    for (final String fileName in webLibraryFileNames) {
      await File('${assets.path}/$fileName').writeAsString('content:$fileName');
    }

    await prepareLibraries(
      packageRoot: packageRoot,
      projectRoot: projectRoot,
      options: const LibraryPreparationOptions(
        target: LibraryPreparationTarget.web,
        force: false,
        webOutput: null,
      ),
    );

    for (final String fileName in webLibraryFileNames) {
      expect(
        await File('${projectRoot.path}/web/rawkit/$fileName').readAsString(),
        'content:$fileName',
      );
    }

    final String updatedFileName = webLibraryFileNames.first;
    await File(
      '${assets.path}/$updatedFileName',
    ).writeAsString('updated:$updatedFileName');
    await prepareLibraries(
      packageRoot: packageRoot,
      projectRoot: projectRoot,
      options: const LibraryPreparationOptions(
        target: LibraryPreparationTarget.web,
        force: false,
        webOutput: null,
      ),
    );
    expect(
      await File(
        '${projectRoot.path}/web/rawkit/$updatedFileName',
      ).readAsString(),
      'updated:$updatedFileName',
    );
  });
}
