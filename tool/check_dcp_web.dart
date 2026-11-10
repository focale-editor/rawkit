import 'dart:io';

import 'package:rawkit/rawkit.dart';
import 'package:rawkit/src/develop/linear_image.dart';
import 'package:rawkit/src/native/native_backend.dart';

import '../test/support/synthetic_dcp.dart';
import '../test/support/synthetic_dng.dart';

/// Produces matching native and WebAssembly inputs for the colour parity check.
Future<void> main(List<String> arguments) async {
  final Directory directory = Directory(arguments.single)..createSync(recursive: true);
  final File dng = File('${directory.path}/source.dng')..writeAsBytesSync(buildSyntheticDng(width: 64, height: 48, orientation: 1, capturedAt: DateTime.utc(2020)));
  final NativeRawDocument document = NativeRawDocument.openMemory(dng.readAsBytesSync());
  try {
    for (int index = 0; index < 4; index++) {
      final File dcp = File('${directory.path}/profile$index.dcp')
        ..writeAsBytesSync(
          buildSyntheticDcp(
            forward: index != 3,
            exposure: index == 1 ? .7 : 0,
            fields: index == 2
                ? {
                    50937: [2, 2, 2],
                    50938: [0, 1, 1, 20, .8, 1, 0, 1, 1, -20, 1.2, 1, 0, 1, 1, 10, .9, 1, 0, 1, 1, -10, 1.1, 1],
                    51107: [1],
                    50940: [0, 0, .4, .5, 1, 1],
                  }
                : const {},
          ),
        );
      final RawDevelopSettings settings = RawDevelopSettings.defaults.copyWith(cameraProfile: RawCameraProfile.fromBytes(dcp.readAsBytesSync()));
      for (final RawColorSpace space in RawColorSpace.values) {
        final LinearImage image = document.decode(settings: settings, colorSpace: space, halfSize: false);
        File('${directory.path}/native$index-${space.index}.bin').writeAsBytesSync(image.pixels.buffer.asUint8List());
      }
    }
  } finally {
    document.close();
  }
}
