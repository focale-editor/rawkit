import 'dart:io';

import 'libraw_downloader.dart';

/// Emscripten release used to produce RawKit's published WebAssembly assets.
const String emscriptenVersion = '4.0.15';

/// Reports whether [directory] contains every published browser artifact.
bool hasWebLibrary(Directory directory) => webLibraryFileNames.every(
  (fileName) => File(
    '${directory.path}${Platform.pathSeparator}$fileName',
  ).existsSync(),
);

/// Browser artifacts copied into Flutter or plain Dart Web applications.
const List<String> webLibraryFileNames = <String>[
  'rawkit_web.mjs',
  'rawkit_web.wasm',
  'rawkit_web_worker.js',
];

/// Builds the pinned LibRaw release as RawKit's browser WebAssembly module.
Future<void> buildWebLibrary({
  required Directory packageRoot,
  String? compiler,
  void Function(String message)? log,
}) async {
  final Directory libRawDirectory = Directory(
    '${packageRoot.path}${Platform.pathSeparator}native'
    '${Platform.pathSeparator}third_party${Platform.pathSeparator}libraw',
  );
  await installLibRaw(libRawDirectory, log: log);
  final Directory outputDirectory = Directory(
    '${packageRoot.path}${Platform.pathSeparator}assets'
    '${Platform.pathSeparator}web',
  );
  await outputDirectory.create(recursive: true);
  final Directory sourceDirectory = Directory(
    '${libRawDirectory.path}${Platform.pathSeparator}src',
  );
  final String packagePrefix = '${packageRoot.absolute.path}${Platform.pathSeparator}';
  final List<String> sources =
      sourceDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.cpp'))
          .where(
            (file) => !file.path.endsWith('preprocessing_ph.cpp') && !file.path.endsWith('postprocessing_ph.cpp') && !file.path.endsWith('write_ph.cpp'),
          )
          .map((file) => file.absolute.path.replaceFirst(packagePrefix, ''))
          .toList()
        ..sort();
  final String executable = compiler ?? Platform.environment['RAWKIT_EMXX'] ?? (Platform.isWindows ? 'em++.bat' : 'em++');
  await _verifyEmscriptenVersion(executable);
  const String outputPath = 'assets/web/rawkit_web.mjs';
  final List<String> arguments = <String>[
    '-O3',
    '-flto',
    '-std=c++11',
    '-fexceptions',
    '-DLIBRAW_NODLL',
    '-DLIBRAW_BUILDLIB',
    '-DLIBRAW_CALLOC_RAWSTORE',
    '-DNOMINMAX',
    '-DNDEBUG',
    '-Inative/include',
    '-Inative/third_party/libraw',
    'native/src/rawkit.cpp',
    ...sources,
    '-sMODULARIZE=1',
    '-sEXPORT_ES6=1',
    '-sEXPORT_NAME=createRawKitModule',
    '-sENVIRONMENT=worker',
    '-sFILESYSTEM=0',
    '-sALLOW_MEMORY_GROWTH=1',
    '-sINITIAL_MEMORY=67108864',
    '-sMAXIMUM_MEMORY=2147483648',
    '-sASSERTIONS=0',
    '-sEXPORTED_RUNTIME_METHODS=["UTF8ToString","HEAPU8","HEAP32","HEAPU32"]',
    '-sEXPORTED_FUNCTIONS=["_malloc","_free","_rawkit_open_memory","_rawkit_close","_rawkit_image_free","_rawkit_error_message","_rawkit_runtime_version","_rawkit_bundled_version","_rawkit_api_version","_rawkit_web_metadata_string","_rawkit_web_metadata_number","_rawkit_web_decode","_rawkit_web_image_width","_rawkit_web_image_height","_rawkit_web_image_channels","_rawkit_web_image_bits_per_sample","_rawkit_web_image_data"]',
    '-o',
    outputPath,
  ];
  log?.call('Building LibRaw $libRawVersion for WebAssembly...');
  final ProcessResult result = await Process.run(
    executable,
    arguments,
    workingDirectory: packageRoot.path,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  if (!hasWebLibrary(outputDirectory)) {
    throw StateError('Emscripten did not produce the expected Web artifacts.');
  }
  log?.call('Built RawKit Web assets in ${outputDirectory.path}.');
}

/// Rejects non-pinned compilers so published assets remain reproducible.
Future<void> _verifyEmscriptenVersion(String executable) async {
  final ProcessResult result = await Process.run(executable, const <String>[
    '--version',
  ]);
  final String versionOutput = '${result.stdout}\n${result.stderr}';
  if (result.exitCode != 0 || !versionOutput.contains('Emscripten') || !versionOutput.contains(' $emscriptenVersion ')) {
    throw StateError(
      'RawKit Web assets require Emscripten $emscriptenVersion. '
      'Compiler output: $versionOutput',
    );
  }
}

/// Builds Web assets when this tool is invoked directly by a maintainer.
Future<void> main(List<String> arguments) async {
  if (arguments.length > 1 || (arguments.isNotEmpty && !arguments.single.startsWith('--compiler='))) {
    stderr.writeln(
      'Usage: dart run tool/web_library_builder.dart [--compiler=/path/to/em++]',
    );
    exitCode = 64;
    return;
  }
  final String? compiler = arguments.isEmpty ? null : arguments.single.substring('--compiler='.length);
  try {
    final Directory packageRoot = File.fromUri(
      Platform.script,
    ).parent.parent;
    await buildWebLibrary(
      packageRoot: packageRoot,
      compiler: compiler,
      log: stdout.writeln,
    );
  } on Object catch (error) {
    stderr.writeln('Could not build RawKit Web assets: $error');
    exitCode = 1;
  }
}
