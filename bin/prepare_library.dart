/// Prepares RawKit's pinned decoder dependencies for offline builds.
library;

import 'dart:io';
import 'dart:isolate';

import '../tool/library_preparer.dart';

/// Installs desktop sources or copies browser assets when invoked with Dart.
Future<void> main(List<String> arguments) async {
  try {
    final LibraryPreparationOptions options = LibraryPreparationOptions.parse(arguments);
    final Directory packageRoot = await _packageRoot();
    await prepareLibraries(
      packageRoot: packageRoot,
      projectRoot: Directory.current,
      options: options,
      log: stdout.writeln,
    );
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(
      'Usage: dart run rawkit:prepare_library '
      '[desktop|web|all] [--force] [--output=directory]',
    );
    exitCode = 64;
  } on Object catch (error) {
    stderr.writeln('Could not prepare RawKit libraries: $error');
    exitCode = 1;
  }
}

/// Locates RawKit whether this executable comes from a path or Pub dependency.
Future<Directory> _packageRoot() async {
  final Uri? libraryUri = await Isolate.resolvePackageUri(
    Uri.parse('package:rawkit/rawkit.dart'),
  );
  if (libraryUri == null || libraryUri.scheme != 'file') {
    throw StateError('Could not locate the installed RawKit package.');
  }
  return File.fromUri(libraryUri).parent.parent;
}
