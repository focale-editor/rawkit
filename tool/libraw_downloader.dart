import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// LibRaw release compiled by RawKit's native build hook.
const String libRawVersion = '0.22.2';

const String _archiveName = 'LibRaw-$libRawVersion.tar.gz';
const String _archiveSha256 =
    'de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa';
final Uri _archiveUri = Uri.parse('https://www.libraw.org/data/$_archiveName');

/// Reports whether [directory] contains the LibRaw source layout RawKit needs.
bool hasLibRawSource(Directory directory) {
  final String separator = Platform.pathSeparator;
  return File('${directory.path}${separator}libraw${separator}libraw.h')
          .existsSync() &&
      Directory('${directory.path}${separator}src').existsSync();
}

/// Downloads the pinned LibRaw archive into [destination] after SHA-256 verification.
///
/// A valid existing installation is reused unless [force] is true. [log]
/// receives concise progress messages suitable for a command-line tool or a
/// Dart build hook.
Future<Directory> installLibRaw(
  Directory destination, {
  bool force = false,
  void Function(String message)? log,
}) async {
  if (hasLibRawSource(destination) && !force) {
    log?.call('Using LibRaw $libRawVersion from ${destination.path}.');
    return destination;
  }

  final Directory parent = destination.parent;
  await parent.create(recursive: true);
  final Directory temporaryDirectory = await parent.createTemp(
    '.rawkit-libraw-',
  );
  try {
    final File archive = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}$_archiveName',
    );
    log?.call('Downloading LibRaw $libRawVersion...');
    final String checksum = await _download(archive);
    if (checksum != _archiveSha256) {
      throw StateError(
        'LibRaw checksum mismatch. Expected $_archiveSha256, got $checksum.',
      );
    }

    final Archive extracted = TarDecoder().decodeBytes(
      GZipDecoder().decodeBytes(await archive.readAsBytes(), verify: true),
      verify: true,
    );
    await extractArchiveToDisk(extracted, temporaryDirectory.path);
    final Directory source = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}LibRaw-$libRawVersion',
    );
    if (!hasLibRawSource(source)) {
      throw StateError('The downloaded archive has an unexpected layout.');
    }

    if (destination.existsSync()) {
      await destination.delete(recursive: true);
    }
    await source.rename(destination.path);
    log?.call('Installed LibRaw $libRawVersion in ${destination.path}.');
    return destination;
  } finally {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  }
}

Future<String> _download(File destination) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(_archiveUri);
    request.followRedirects = true;
    request.headers.set(HttpHeaders.userAgentHeader, 'RawKit/0.1.0');
    final HttpClientResponse response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException(
        'The LibRaw server returned HTTP ${response.statusCode}.',
        uri: _archiveUri,
      );
    }

    final IOSink output = destination.openWrite();
    final _DigestCollector digests = _DigestCollector();
    final ByteConversionSink checksum = sha256.startChunkedConversion(digests);
    try {
      await for (final List<int> chunk in response) {
        output.add(chunk);
        checksum.add(chunk);
      }
      checksum.close();
      await output.close();
      final Digest? digest = digests.value;
      if (digest == null) {
        throw StateError('The LibRaw checksum was not produced.');
      }
      return digest.toString();
    } on Object {
      await output.close();
      rethrow;
    }
  } finally {
    client.close(force: true);
  }
}

/// Receives the single digest emitted by the streaming SHA-256 converter.
final class _DigestCollector implements Sink<Digest> {
  /// The digest received from the converter.
  Digest? value;

  @override
  void add(Digest data) {
    if (value != null) {
      throw StateError('The LibRaw checksum was emitted more than once.');
    }
    value = data;
  }

  @override
  void close() {}
}
