import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import '../tool/libraw_downloader.dart';

/// Builds the bundled native decoder as a Dart code asset.
void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final String packageRoot = input.packageRoot.toFilePath();
    final Directory packageLibRawDirectory = Directory(
      '${packageRoot}native/third_party/libraw',
    );
    final Directory libRawDirectory = hasLibRawSource(packageLibRawDirectory)
        ? packageLibRawDirectory
        : await installLibRaw(
            Directory.fromUri(
              input.outputDirectoryShared.resolve('libraw-$libRawVersion/'),
            ),
            log: stdout.writeln,
          );
    final Directory sourceDirectory = Directory(
      '${libRawDirectory.path}${Platform.pathSeparator}src',
    );
    output.dependencies.add(libRawDirectory.uri);
    final List<String> libRawSources =
        sourceDirectory
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.cpp'))
            .where(
              (file) =>
                  !file.path.endsWith('preprocessing_ph.cpp') &&
                  !file.path.endsWith('postprocessing_ph.cpp') &&
                  !file.path.endsWith('write_ph.cpp'),
            )
            .map((file) => file.path)
            .toList()
          ..sort();
    final String shimSource = '${packageRoot}native/src/rawkit.cpp';
    final String shimInclude = '${packageRoot}native/include';

    final CBuilder builder = CBuilder.library(
      name: 'rawkit',
      assetName: 'src/native/bindings.dart',
      sources: [shimSource, ...libRawSources],
      includes: [shimInclude, libRawDirectory.path],
      defines: const {
        'LIBRAW_NODLL': null,
        'LIBRAW_BUILDLIB': null,
        'LIBRAW_CALLOC_RAWSTORE': null,
        'NOMINMAX': null,
      },
      language: Language.cpp,
      std: 'c++11',
    );
    final bool buildHostLinuxDirectly =
        Platform.isLinux &&
        input.config.code.targetOS == OS.linux &&
        input.config.code.targetArchitecture == Architecture.current;
    if (buildHostLinuxDirectly) {
      await _buildHostLinux(
        input: input,
        output: output,
        sources: [shimSource, ...libRawSources],
        includes: [shimInclude, libRawDirectory.path],
      );
    } else {
      await builder.run(input: input, output: output);
    }
    output.dependencies.addAll(
      Directory('${packageRoot}native')
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.uri),
    );
  });
}

/// Works around launchers that canonicalize a ccache compiler symlink to the
/// ccache binary itself, losing the compiler name that ccache needs.
Future<void> _buildHostLinux({
  required BuildInput input,
  required BuildOutputBuilder output,
  required List<String> sources,
  required List<String> includes,
}) async {
  final String compiler = _findRealLinuxCompiler();
  final String packageRoot = input.packageRoot.toFilePath();
  final Uri library = input.outputDirectory.resolve('librawkit.so');
  await Directory.fromUri(input.outputDirectory).create(recursive: true);
  final List<String> arguments = [
    '-fPIC',
    '-std=c++11',
    '-O3',
    '-DLIBRAW_NODLL',
    '-DLIBRAW_BUILDLIB',
    '-DLIBRAW_CALLOC_RAWSTORE',
    '-DNOMINMAX',
    '-DNDEBUG',
    ...includes.map((directory) => '-I$directory'),
    ...sources,
    '-shared',
    '-o',
    library.toFilePath(),
    r'-Wl,-rpath,$ORIGIN',
  ];
  final ProcessResult result = await Process.run(
    compiler,
    arguments,
    workingDirectory: packageRoot,
  );
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    throw ProcessException(
      compiler,
      arguments,
      'Native RawKit compilation failed.',
      result.exitCode,
    );
  }
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/native/bindings.dart',
      file: library,
      linkMode: DynamicLoadingBundled(),
    ),
  );
}

/// Finds the real clang++ or g++ executable.
String _findRealLinuxCompiler() {
  const List<String> candidates = [
    '/usr/bin/clang++',
    '/usr/bin/g++',
    '/bin/clang++',
    '/bin/g++',
  ];
  for (final String candidate in candidates) {
    final File file = File(candidate);
    if (file.existsSync() &&
        !file.resolveSymbolicLinksSync().endsWith('/ccache')) {
      return candidate;
    }
  }
  throw StateError(
    'The configured compiler resolves to ccache without a compiler name, and '
    'no real clang++ or g++ executable was found.',
  );
}
