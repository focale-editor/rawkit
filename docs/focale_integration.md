# Integrating RawKit into Focale

RawKit deliberately stops at a Dart-owned RGB buffer. Focale currently stores
opaque imported images as premultiplied 8-bit RGBA raster assets, so the clean
integration point is its document import service rather than its image engine's
encoded-image decoder.

## Recommended boundary

1. Add RawKit as a path dependency in Focale.
2. Recognize RAW extensions before `ImageFormat.sniff`, which only handles
   encoded display formats.
3. Open the file with `RawDocument.openFile` and present development settings
   in Focale's import flow.
4. Render `RawBitDepth.uint8` in `RawColorSpace.srgb` for Focale's current
   8-bit engine.
5. Convert the returned RGB samples with `RawImage.toRgba8()`.
6. Create a `dart:ui` image and pass ownership to `ImageEngine.adoptImage`.
7. Keep the `RawDocument` open only while an interactive development dialog is
   active, then close it after the chosen raster has been adopted.

The conversion itself remains in Focale because `dart:ui` would make RawKit a
Flutter-specific package:

```dart
import 'dart:async';
import 'dart:ui' as ui;

import 'package:rawkit/rawkit.dart';

Future<ui.Image> developRawForFocale(String path) async {
  final RawDocument document = await RawDocument.openFile(path);
  try {
    final RawImage image = await document.render(
      RawDevelopSettings.defaults,
      bitDepth: RawBitDepth.uint8,
      colorSpace: RawColorSpace.srgb,
    );
    final rgba = image.toRgba8();
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      image.width,
      image.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  } finally {
    await document.close();
  }
}
```

All generated alpha values are 255, so straight and premultiplied RGBA are
identical at this boundary. Focale can then call
`engine.adoptImage(assetId, image)` and construct its ordinary raster layer.

## Preview flow

For an interactive dialog, retain one `RawDocument`, call `renderPreview` as
sliders change, and only call full-resolution `render` after confirmation.
Tonal changes reuse RawKit's cached linear preview. White balance, demosaicing,
highlight-recovery, or output-primary changes correctly trigger a native
development pass.

The current Focale engine is 8-bit, so a 16-bit RawKit render would be reduced
when adopted. Keep the 16-bit option for future high-precision engine work or
for a separate export path.
