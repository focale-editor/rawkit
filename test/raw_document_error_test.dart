import 'dart:io';
import 'dart:typed_data';

import 'package:rawkit/rawkit.dart';
import 'package:test/test.dart';

void main() {
  test('empty memory input fails without leaking a worker', () async {
    await expectLater(
      RawDocument.openMemory(Uint8List(0)),
      throwsA(isA<RawIOException>()),
    );
  });

  test('unsupported memory input has a typed failure', () async {
    await expectLater(
      RawDocument.openMemory(Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8])),
      throwsA(
        anyOf(
          isA<RawUnsupportedFileException>(),
          isA<RawDecodeException>(),
          isA<RawIOException>(),
        ),
      ),
    );
  });

  test('missing file has a typed IO failure', () async {
    final Directory temporaryDirectory = await Directory.systemTemp.createTemp(
      'rawkit-missing-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    await expectLater(
      RawDocument.openFile('${temporaryDirectory.path}/missing.dng'),
      throwsA(isA<RawIOException>()),
    );
  });
}
