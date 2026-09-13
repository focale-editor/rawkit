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
              (file) => !file.path.endsWith('preprocessing_ph.cpp') && !file.path.endsWith('postprocessing_ph.cpp') && !file.path.endsWith('write_ph.cpp'),
            )
            .map((file) => file.path)
            .toList()
          ..sort();
    final String shimSource = '${packageRoot}native/src/rawkit.cpp';
    final String shimInclude = '${packageRoot}native/include';

    final bool buildHostLinuxDirectly = Platform.isLinux && input.config.code.targetOS == OS.linux && input.config.code.targetArchitecture == Architecture.current;
    if (buildHostLinuxDirectly) {
      await _buildHostLinux(
        input: input,
        output: output,
        sources: [shimSource, ...libRawSources],
        includes: [shimInclude, libRawDirectory.path],
      );
    } else {
      final bool targetsWindows = input.config.code.targetOS == OS.windows;
      final File? windowsOpenMpRuntime = targetsWindows ? _findWindowsOpenMpRuntime(input.config.code.targetArchitecture) : null;
      await CBuilder.library(
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
        // Only the RawKit C API is exported; LibRaw symbols stay private so
        // they cannot clash with another LibRaw loaded in the same process.
        flags: targetsWindows ? [if (windowsOpenMpRuntime != null) '/openmp'] : const ['-fvisibility=hidden', '-fvisibility-inlines-hidden'],
        language: Language.cpp,
        std: 'c++11',
      ).run(input: input, output: output);
      if (windowsOpenMpRuntime != null) {
        _bundleOpenMpRuntime(input, output, windowsOpenMpRuntime, 'vcomp140.dll');
      }
    }
    output.dependencies.addAll(
      Directory('${packageRoot}native').listSync(recursive: true).whereType<File>().map((file) => file.uri),
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
  final _LinuxOpenMpRuntime? openMpRuntime = await _findLinuxOpenMpRuntime(
    compiler,
    input.outputDirectory,
  );
  final List<String> arguments = [
    '-fPIC',
    '-std=c++11',
    '-O3',
    // Only the RawKit C API is exported; LibRaw symbols stay private so they
    // cannot clash with another LibRaw loaded in the same process.
    '-fvisibility=hidden',
    '-fvisibility-inlines-hidden',
    if (openMpRuntime != null) '-fopenmp',
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
  if (openMpRuntime != null) {
    _bundleOpenMpRuntime(input, output, openMpRuntime.file, openMpRuntime.soname);
  }
}

/// OpenMP runtime library that a Linux build links against and bundles.
final class _LinuxOpenMpRuntime {
  /// Creates a runtime description.
  const _LinuxOpenMpRuntime({required this.file, required this.soname});

  /// Runtime library resolved by the compiler.
  final File file;

  /// Name recorded as a dependency of `librawkit.so`.
  final String soname;
}

/// Finds an OpenMP runtime usable by [compiler], or `null` to build serially.
///
/// OpenMP parallelizes LibRaw's demosaicing. The runtime is bundled next to
/// `librawkit.so`, so applications never depend on it being installed; when
/// the compiler cannot build OpenMP code or its runtime cannot be located,
/// RawKit is built without parallelism instead of failing.
Future<_LinuxOpenMpRuntime?> _findLinuxOpenMpRuntime(
  String compiler,
  Uri outputDirectory,
) async {
  final ProcessResult version = await Process.run(compiler, const ['--version']);
  final String soname = '${version.stdout}'.contains('clang') ? 'libomp.so' : 'libgomp.so.1';
  final ProcessResult location = await Process.run(compiler, ['-print-file-name=$soname']);
  final String path = '${location.stdout}'.trim();
  if (location.exitCode != 0 || !path.startsWith('/') || !File(path).existsSync()) {
    return null;
  }
  final Directory probeDirectory = await Directory.fromUri(outputDirectory).createTemp('openmp-probe-');
  try {
    final File source = File('${probeDirectory.path}/probe.cpp')
      ..writeAsStringSync(
        '#include <omp.h>\n'
        'int rawkit_openmp_probe() {\n'
        '  int count = 0;\n'
        '#pragma omp parallel reduction(+:count)\n'
        '  count++;\n'
        '  return count;\n'
        '}\n',
      );
    final ProcessResult probe = await Process.run(compiler, [
      '-fopenmp',
      '-fPIC',
      '-shared',
      source.path,
      '-o',
      '${probeDirectory.path}/probe.so',
    ]);
    if (probe.exitCode != 0) {
      return null;
    }
  } finally {
    await probeDirectory.delete(recursive: true);
  }
  return _LinuxOpenMpRuntime(
    file: File(File(path).resolveSymbolicLinksSync()),
    soname: soname,
  );
}

/// Finds the MSVC OpenMP runtime DLL for [architecture], if installed.
///
/// Visual Studio installs it under
/// `<year>\<edition>\VC\Redist\MSVC\<version>\<arch>\Microsoft.VC*.OpenMP`.
/// Without it, the Windows build compiles LibRaw serially.
File? _findWindowsOpenMpRuntime(Architecture architecture) {
  final String? architectureDirectory = switch (architecture) {
    Architecture.x64 => 'x64',
    Architecture.arm64 => 'arm64',
    Architecture.ia32 => 'x86',
    _ => null,
  };
  if (architectureDirectory == null || !Platform.isWindows) {
    return null;
  }
  List<Directory> children(Directory directory) {
    try {
      return directory.listSync(followLinks: false).whereType<Directory>().toList()..sort((first, second) => second.path.compareTo(first.path));
    } on FileSystemException {
      return const [];
    }
  }

  final List<Directory> redistributableRoots = [
    if (Platform.environment['VCToolsRedistDir'] case final String toolsRedistributable) Directory(toolsRedistributable),
    for (final String? programFiles in [Platform.environment['ProgramFiles'], Platform.environment['ProgramFiles(x86)']])
      if (programFiles != null)
        for (final Directory year in children(Directory('$programFiles\\Microsoft Visual Studio')))
          for (final Directory edition in children(year)) ...children(Directory('${edition.path}\\VC\\Redist\\MSVC')),
  ];
  for (final Directory root in redistributableRoots) {
    for (final Directory runtimeDirectory in children(Directory('${root.path}\\$architectureDirectory'))) {
      final String name = runtimeDirectory.uri.pathSegments.where((segment) => segment.isNotEmpty).last.toLowerCase();
      final File runtime = File('${runtimeDirectory.path}\\vcomp140.dll');
      if (name.startsWith('microsoft.vc') && name.endsWith('.openmp') && runtime.existsSync()) {
        return runtime;
      }
    }
  }
  return null;
}

/// Bundles an OpenMP [runtime] beside the RawKit library as [fileName].
///
/// The copy keeps the dependency name recorded in the RawKit library, so the
/// platform loader finds it in the application's native library directory.
void _bundleOpenMpRuntime(
  BuildInput input,
  BuildOutputBuilder output,
  File runtime,
  String fileName,
) {
  final Uri bundled = input.outputDirectory.resolve(fileName);
  runtime.copySync(bundled.toFilePath());
  output.dependencies.add(runtime.uri);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/native/openmp_runtime.dart',
      file: bundled,
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
    if (file.existsSync() && !file.resolveSymbolicLinksSync().endsWith('/ccache')) {
      return candidate;
    }
  }
  throw StateError(
    'The configured compiler resolves to ccache without a compiler name, and '
    'no real clang++ or g++ executable was found.',
  );
}
