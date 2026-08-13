/// Downloads the pinned LibRaw source required by RawKit's native build hook.
library;

import 'dart:io';
import 'dart:isolate';

import '../tool/libraw_downloader.dart';

/// Downloads and verifies LibRaw when this executable is invoked with Dart.
Future<void> main(List<String> arguments) async {
  try {
    final bool force = _parseArguments(arguments);
    final Directory packageRoot = await _packageRoot();
    final Directory destination = Directory(
      '${packageRoot.path}${Platform.pathSeparator}native${Platform.pathSeparator}'
      'third_party${Platform.pathSeparator}libraw',
    );
    await installLibRaw(destination, force: force, log: stdout.writeln);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('Usage: dart run rawkit:download_library [--force]');
    exitCode = 64;
  } on Object catch (error) {
    stderr.writeln('Could not install LibRaw: $error');
    exitCode = 1;
  }
}

bool _parseArguments(List<String> arguments) {
  if (arguments.isEmpty) {
    return false;
  }
  if (arguments.length == 1 && arguments.single == '--force') {
    return true;
  }
  throw const FormatException('Unknown command-line arguments.');
}

Future<Directory> _packageRoot() async {
  final Uri? libraryUri = await Isolate.resolvePackageUri(
    Uri.parse('package:rawkit/rawkit.dart'),
  );
  if (libraryUri == null || libraryUri.scheme != 'file') {
    throw StateError('Could not locate the installed RawKit package.');
  }
  return File.fromUri(libraryUri).parent.parent;
}
