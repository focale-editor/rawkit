import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rawkit/rawkit.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2) {
    stderr.writeln(
      'Usage: dart run example/rawkit_example.dart <input.raw> [output.ppm]',
    );
    exitCode = 64;
    return;
  }

  final String inputPath = arguments.first;
  final String outputPath = arguments.length == 2
      ? arguments[1]
      : '$inputPath.developed.ppm';
  final String previewPath = '$outputPath.preview.ppm';
  final RawDocument document = await RawDocument.openFile(inputPath);
  try {
    final RawMetadata metadata = document.metadata;
    stdout
      ..writeln('Backend: ${document.backendInfo}')
      ..writeln('Camera: ${metadata.cameraMake} ${metadata.cameraModel}')
      ..writeln('Lens: ${metadata.lens ?? 'unknown'}')
      ..writeln('ISO: ${metadata.iso ?? 'unknown'}')
      ..writeln('Aperture: f/${metadata.aperture ?? 'unknown'}')
      ..writeln('Shutter: ${metadata.shutterSpeed ?? 'unknown'} s')
      ..writeln('Focal length: ${metadata.focalLength ?? 'unknown'} mm')
      ..writeln('Visible size: ${metadata.width} × ${metadata.height}');

    final RawDevelopSettings settings = RawDevelopSettings.defaults.copyWith(
      whiteBalance: RawWhiteBalance.camera,
      exposure: 0.7,
      contrast: 8,
      highlights: -30,
      shadows: 25,
      vibrance: 10,
      demosaicQuality: RawDemosaicQuality.high,
      highlightRecovery: RawHighlightRecovery.reconstruct,
    );

    final RawImage preview = await document.renderPreview(
      settings,
      maxWidth: 1600,
      bitDepth: RawBitDepth.uint8,
    );
    await _writePpm(preview, previewPath);
    stdout.writeln(
      'Preview: $previewPath (${preview.width} × ${preview.height})',
    );

    final RawImage finalImage = await document.render(
      settings,
      bitDepth: RawBitDepth.uint16,
      colorSpace: RawColorSpace.srgb,
    );
    await _writePpm(finalImage, outputPath);
    stdout.writeln(
      'Final: $outputPath (${finalImage.width} × ${finalImage.height}, 16-bit)',
    );
  } on RawException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    await document.close();
  }
}

Future<void> _writePpm(RawImage image, String path) async {
  if (image.channels != 3 || image.colorSpace != RawColorSpace.srgb) {
    throw ArgumentError('The PPM example expects a three-channel sRGB image.');
  }
  final BytesBuilder output = BytesBuilder(copy: false)
    ..add(ascii.encode('P6\n${image.width} ${image.height}\n'));
  switch (image.bitDepth) {
    case RawBitDepth.uint8:
      output
        ..add(ascii.encode('255\n'))
        ..add(image.pixels8);
    case RawBitDepth.uint16:
      output.add(ascii.encode('65535\n'));
      final Uint16List samples = image.pixels16;
      final Uint8List bigEndian = Uint8List(samples.length * 2);
      final ByteData bytes = bigEndian.buffer.asByteData();
      for (int index = 0; index < samples.length; index++) {
        bytes.setUint16(index * 2, samples[index], Endian.big);
      }
      output.add(bigEndian);
  }
  await File(path).writeAsBytes(output.takeBytes(), flush: true);
}
