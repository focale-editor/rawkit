import 'dart:io';

import 'package:rawkit/rawkit.dart';
import 'package:test/test.dart';

void main() {
  const String compileTimeCorpusPath = String.fromEnvironment(
    'RAWKIT_TEST_CORPUS',
  );
  final String? corpusPath =
      Platform.environment['RAWKIT_TEST_CORPUS'] ??
      (compileTimeCorpusPath.isEmpty ? null : compileTimeCorpusPath);
  final List<File> rawFiles = corpusPath == null
      ? const []
      : _findRawFiles(Directory(corpusPath));

  test(
    'open, metadata, preview, render, close lifecycle',
    () async {
      final RawDocument document = await RawDocument.openFile(
        rawFiles.first.path,
      );
      try {
        expect(document.metadata.width, greaterThan(0));
        expect(document.metadata.height, greaterThan(0));

        final RawDevelopSettings settings = RawDevelopSettings.defaults
            .copyWith(exposure: 0.25, highlights: -20, shadows: 15);
        final RawImage preview = await document.renderPreview(
          settings,
          maxWidth: 640,
        );
        expect(preview.width, lessThanOrEqualTo(640));
        expect(preview.channels, 3);
        expect(preview.byteLength, preview.expectedByteLength);

        final RawImage full = await document.render(
          settings,
          bitDepth: RawBitDepth.uint16,
        );
        expect(full.width, greaterThanOrEqualTo(preview.width));
        expect(full.channels, 3);
        expect(full.pixels16.length, full.sampleCount);
      } finally {
        await document.close();
        await document.close();
      }
      expect(document.isClosed, isTrue);
      expect(
        () => document.renderPreview(RawDevelopSettings.defaults),
        throwsA(isA<RawStateException>()),
      );
    },
    skip: rawFiles.isEmpty
        ? 'Set RAWKIT_TEST_CORPUS to a directory containing licensed RAW files.'
        : false,
  );

  test(
    'multiple documents can coexist',
    () async {
      final File firstFile = rawFiles.first;
      final File secondFile = rawFiles.length > 1 ? rawFiles[1] : firstFile;
      final List<RawDocument> documents = await Future.wait([
        RawDocument.openFile(firstFile.path),
        RawDocument.openFile(secondFile.path),
      ]);
      try {
        final List<RawImage> previews = await Future.wait(
          documents.map(
            (document) => document.renderPreview(
              RawDevelopSettings.defaults,
              maxWidth: 320,
            ),
          ),
        );
        expect(previews, hasLength(2));
        expect(previews.every((image) => image.width <= 320), isTrue);
      } finally {
        await Future.wait(documents.map((document) => document.close()));
      }
    },
    skip: rawFiles.isEmpty
        ? 'Set RAWKIT_TEST_CORPUS to a directory containing licensed RAW files.'
        : false,
  );

  test(
    'memory input is copied and supports custom white balance',
    () async {
      final bytes = await rawFiles.first.readAsBytes();
      final RawDocument document = await RawDocument.openMemory(bytes);

      // A later decode reopens the worker-owned copy, not this caller buffer.
      bytes.fillRange(0, bytes.length, 0);
      try {
        final RawImage preview = await document.renderPreview(
          RawDevelopSettings.defaults.copyWith(
            whiteBalance: RawWhiteBalance.custom,
            temperature: 5200,
            tint: 8,
          ),
          maxWidth: 256,
        );
        expect(preview.width, lessThanOrEqualTo(256));
        expect(preview.toRgba8().length, preview.width * preview.height * 4);
      } finally {
        await document.close();
      }
    },
    skip: rawFiles.isEmpty
        ? 'Set RAWKIT_TEST_CORPUS to a directory containing licensed RAW files.'
        : false,
  );
}

List<File> _findRawFiles(Directory directory) {
  if (!directory.existsSync()) {
    return const [];
  }
  const Set<String> extensions = {
    '3fr',
    'arw',
    'cr2',
    'cr3',
    'dng',
    'nef',
    'orf',
    'raf',
    'rw2',
  };
  final List<File> files =
      directory
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) {
            final String name = file.path.toLowerCase();
            final int dot = name.lastIndexOf('.');
            return dot >= 0 && extensions.contains(name.substring(dot + 1));
          })
          .toList()
        ..sort((first, second) => first.path.compareTo(second.path));
  return files;
}
