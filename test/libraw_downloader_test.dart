@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zcodec/zcodec.dart';

import '../tool/libraw_downloader.dart';

void main() {
  group('extractArchiveToDisk', () {
    test(
      'extracts directories, files, links, and ordinary permissions',
      () async {
        final Directory temporary = await Directory.systemTemp.createTemp(
          'rawkit-extractor-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final Directory destination = Directory('${temporary.path}/output');
        final List<TarEntry> entries = <TarEntry>[
          TarEntry(
            name: 'LibRaw/script.sh',
            data: utf8.encode('#!/bin/sh\nexit 0\n'),
            mode: 0x1e9,
          ),
          TarEntry(name: 'LibRaw/', type: TarEntryType.directory, mode: 0x1ed),
          TarEntry(
            name: 'LibRaw/script-copy.sh',
            type: TarEntryType.hardLink,
            linkName: 'LibRaw/script.sh',
            mode: 0x1e9,
          ),
          if (!Platform.isWindows)
            TarEntry(
              name: 'LibRaw/subdirectory/script-link.sh',
              type: TarEntryType.symbolicLink,
              linkName: '../script.sh',
            ),
        ];

        await extractArchiveToDisk(TarArchive(entries: entries), destination);

        expect(
          await File('${destination.path}/LibRaw/script.sh').readAsString(),
          '#!/bin/sh\nexit 0\n',
        );
        expect(
          await File('${destination.path}/LibRaw/script-copy.sh').readAsString(),
          '#!/bin/sh\nexit 0\n',
        );
        if (!Platform.isWindows) {
          expect(
            await Link('${destination.path}/LibRaw/subdirectory/script-link.sh').target(),
            '../script.sh',
          );
          final FileStat stat = await File(
            '${destination.path}/LibRaw/script.sh',
          ).stat();
          expect(stat.mode & 0x1ff, 0x1e9);
        }
      },
    );

    test('rejects unsafe paths before creating the destination', () async {
      final Directory temporary = await Directory.systemTemp.createTemp(
        'rawkit-extractor-unsafe-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final Directory destination = Directory('${temporary.path}/output');
      final TarArchive archive = TarArchive(
        entries: <TarEntry>[
          TarEntry(name: 'safe.txt', data: const <int>[1]),
          TarEntry(name: '../outside.txt', data: const <int>[2]),
        ],
      );

      await expectLater(
        extractArchiveToDisk(archive, destination),
        throwsA(isA<StateError>()),
      );
      expect(destination.existsSync(), isFalse);
      expect(File('${temporary.path}/outside.txt').existsSync(), isFalse);
    });

    test('rejects special entries and escaping symbolic links', () async {
      final Directory temporary = await Directory.systemTemp.createTemp(
        'rawkit-extractor-special-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      await expectLater(
        extractArchiveToDisk(
          TarArchive(
            entries: <TarEntry>[
              TarEntry(name: 'device', type: TarEntryType.characterDevice),
            ],
          ),
          Directory('${temporary.path}/device-output'),
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        extractArchiveToDisk(
          TarArchive(
            entries: <TarEntry>[
              TarEntry(
                name: 'link',
                type: TarEntryType.symbolicLink,
                linkName: '../outside',
              ),
            ],
          ),
          Directory('${temporary.path}/link-output'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'rejects a symbolic-link extraction root',
      () async {
        final Directory temporary = await Directory.systemTemp.createTemp(
          'rawkit-extractor-root-link-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final Directory outside = Directory('${temporary.path}/outside');
        await outside.create();
        final Directory destination = Directory('${temporary.path}/output');
        await Link(destination.path).create(outside.path);

        await expectLater(
          extractArchiveToDisk(
            TarArchive(
              entries: <TarEntry>[
                TarEntry(name: 'escaped.txt', data: const <int>[1]),
              ],
            ),
            destination,
          ),
          throwsA(isA<StateError>()),
        );
        expect(File('${outside.path}/escaped.txt').existsSync(), isFalse);
      },
      skip: Platform.isWindows ? 'Symbolic-link creation may require elevated Windows privileges.' : false,
    );

    test(
      'extracts the official LibRaw source archive',
      () async {
        final String? archivePath = Platform.environment['RAWKIT_TEST_LIBRAW_ARCHIVE'];
        if (archivePath == null) {
          throw StateError('RAWKIT_TEST_LIBRAW_ARCHIVE is missing.');
        }
        final Directory temporary = await Directory.systemTemp.createTemp(
          'rawkit-extractor-libraw-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final Uint8List tarBytes = const GzipCodec(maxOutputBytes: 512 * 1024 * 1024).decode(await File(archivePath).readAsBytes());
        final TarArchive archive = const TarDecoder().convert(tarBytes);

        await extractArchiveToDisk(archive, temporary);

        expect(
          hasLibRawSource(Directory('${temporary.path}/LibRaw-$libRawVersion')),
          isTrue,
        );
      },
      skip: Platform.environment['RAWKIT_TEST_LIBRAW_ARCHIVE'] == null ? 'Set RAWKIT_TEST_LIBRAW_ARCHIVE to run the real-archive check.' : false,
    );
  });
}
