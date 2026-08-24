import 'dart:io';

import 'libraw_downloader.dart';
import 'web_library_builder.dart';

/// Selects the dependency artifacts prepared by the RawKit command-line tool.
enum LibraryPreparationTarget {
  /// Installs LibRaw source for an offline native build.
  desktop,

  /// Copies precompiled browser artifacts into a plain Dart Web project.
  web,

  /// Performs both preparation operations.
  all,
}

/// Parsed command-line configuration for dependency preparation.
final class LibraryPreparationOptions {
  /// Creates validated preparation options.
  const LibraryPreparationOptions({
    required this.target,
    required this.force,
    required this.webOutput,
  });

  /// Platform artifacts to prepare.
  final LibraryPreparationTarget target;

  /// Whether existing installations may be replaced.
  final bool force;

  /// Optional browser artifact destination for plain Dart Web projects.
  final String? webOutput;

  /// Parses `prepare_library` command-line [arguments].
  factory LibraryPreparationOptions.parse(
    List<String> arguments, {
    LibraryPreparationTarget defaultTarget = LibraryPreparationTarget.all,
  }) {
    LibraryPreparationTarget target = defaultTarget;
    bool hasTarget = false;
    bool force = false;
    String? webOutput;
    for (final String argument in arguments) {
      if (argument == '--force') {
        force = true;
      } else if (argument.startsWith('--output=')) {
        webOutput = argument.substring('--output='.length);
        if (webOutput.isEmpty) {
          throw const FormatException('--output requires a directory path.');
        }
      } else if (!argument.startsWith('-') && !hasTarget) {
        target = switch (argument) {
          'desktop' => LibraryPreparationTarget.desktop,
          'web' => LibraryPreparationTarget.web,
          'all' => LibraryPreparationTarget.all,
          _ => throw FormatException('Unknown preparation target: $argument.'),
        };
        hasTarget = true;
      } else {
        throw FormatException('Unknown command-line argument: $argument.');
      }
    }
    if (webOutput != null && target == LibraryPreparationTarget.desktop) {
      throw const FormatException(
        '--output can only be used with the web or all target.',
      );
    }
    return LibraryPreparationOptions(
      target: target,
      force: force,
      webOutput: webOutput,
    );
  }
}

/// Prepares the selected RawKit dependencies and browser assets.
Future<void> prepareLibraries({
  required Directory packageRoot,
  required Directory projectRoot,
  required LibraryPreparationOptions options,
  void Function(String message)? log,
}) async {
  if (options.target != LibraryPreparationTarget.web) {
    final Directory destination = Directory(
      '${packageRoot.path}${Platform.pathSeparator}native'
      '${Platform.pathSeparator}third_party${Platform.pathSeparator}libraw',
    );
    await installLibRaw(
      destination,
      force: options.force,
      log: log,
    );
  }
  if (options.target != LibraryPreparationTarget.desktop) {
    await _copyWebLibrary(
      packageRoot: packageRoot,
      projectRoot: projectRoot,
      outputPath: options.webOutput,
      log: log,
    );
  }
}

/// Copies published Web artifacts into a plain Dart Web application.
Future<void> _copyWebLibrary({
  required Directory packageRoot,
  required Directory projectRoot,
  required String? outputPath,
  required void Function(String message)? log,
}) async {
  final Directory source = Directory(
    '${packageRoot.path}${Platform.pathSeparator}assets'
    '${Platform.pathSeparator}web',
  );
  if (!hasWebLibrary(source)) {
    throw StateError(
      'This RawKit installation does not contain its precompiled Web assets.',
    );
  }
  final Directory destination = outputPath == null
      ? Directory(
          '${projectRoot.path}${Platform.pathSeparator}web'
          '${Platform.pathSeparator}rawkit',
        )
      : Directory(outputPath).absolute;
  await destination.create(recursive: true);
  for (final String fileName in webLibraryFileNames) {
    final File output = File(
      '${destination.path}${Platform.pathSeparator}$fileName',
    );
    await File(
      '${source.path}${Platform.pathSeparator}$fileName',
    ).copy(output.path);
  }
  log?.call('Prepared RawKit Web assets in ${destination.path}.');
  log?.call(
    "Configure RawKit with assetBaseUrl: 'rawkit/' in a plain Dart Web app.",
  );
}
