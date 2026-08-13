import 'dart:io';

import 'package:rawkit/rawkit.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run benchmark/rawkit_benchmark.dart <input.raw>',
    );
    exitCode = 64;
    return;
  }

  final Stopwatch stopwatch = Stopwatch()..start();
  final RawDocument document = await RawDocument.openFile(arguments.single);
  _report('open + metadata', stopwatch);
  try {
    const RawDevelopSettings defaults = RawDevelopSettings.defaults;
    await document.renderPreview(defaults, maxWidth: 1600);
    _report('preview decode + demosaic + tone', stopwatch);

    await document.renderPreview(
      defaults.copyWith(exposure: 0.5, shadows: 20),
      maxWidth: 1600,
    );
    _report('preview tone from cache', stopwatch);

    await document.renderPreview(
      defaults.copyWith(
        whiteBalance: RawWhiteBalance.custom,
        temperature: 5200,
        tint: 8,
      ),
      maxWidth: 1600,
    );
    _report('preview white-balance re-decode', stopwatch);

    await document.render(defaults, bitDepth: RawBitDepth.uint16);
    _report('full decode + demosaic + tone', stopwatch);

    await document.render(
      defaults.copyWith(contrast: 12, highlights: -20),
      bitDepth: RawBitDepth.uint16,
    );
    _report('full tone from cache', stopwatch);
  } finally {
    await document.close();
  }
}

void _report(String label, Stopwatch stopwatch) {
  stdout.writeln('${label.padRight(38)} ${stopwatch.elapsedMilliseconds} ms');
  stopwatch.reset();
}
