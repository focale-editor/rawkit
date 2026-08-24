# RawKit

RawKit is a UI-independent Dart package for opening, inspecting and developing
camera RAW files. It bundles a pinned decoder behind a small C shim, runs
expensive work in a dedicated isolate or Web Worker, caches linear RGB
intermediates, and returns pixels in Dart-owned `Uint8List` or `Uint16List`
buffers.

The package is intended to be the RAW import/development brick of an image editor.
It has no Flutter, widget, image-codec or application dependency.

## Current feature set

* Filesystem and memory-buffer input.
* Camera, lens, exposure, orientation and sensor-size metadata.
* Camera, automatic and custom temperature/tint white balance.
* Fast, balanced and high-quality demosaicing choices.
* Sensor highlight clipping, blending or reconstruction.
* Exposure, contrast, highlights, shadows, whites, blacks, saturation and
  vibrance controls.
* 8-bit and 16-bit RGB output in sRGB, Adobe RGB (1998), or ProPhoto RGB.
* Half-resolution native preview decode plus size-limited resampling.
* Separate preview/full linear caches that survive tonal-only edits.
* Typed errors and idempotent asynchronous cleanup.

RawKit does not provide UI, cataloguing, layer editing, masks, local edits,
image encoding, ICC profile embedding, or export formats such as JPEG/PNG.

## Platforms, assets and prerequisites

RawKit targets Linux, macOS, Windows and the Web. Native source and hooks are
structured for the host architectures supported by Dart's C toolchain. This
revision is validated on Linux x64; macOS arm64/x64 and Windows x64 are yet to
be tested. Dart 3.13 or later is required.

### Desktop

Desktop builds also require a working platform C++ compiler.
On its first desktop build, RawKit downloads the pinned LibRaw
source into the project's `.dart_tool` hook cache, verifies its SHA-256, and
then compiles it. Web consumers use the precompiled package asset and need no
compiler. No manual setup is required on either path.

To pre-download the source for an offline desktop build, run:

```console
dart run rawkit:prepare_library desktop
```

The command locates the installed RawKit package and extracts LibRaw beside its
native build files. The automatic build path instead uses the project-local
hook cache. LibRaw source is therefore not included in the published RawKit
archive. Re-run the command after upgrading RawKit or clearing the Pub cache.

The Dart build hook then compiles and bundles the native code asset
automatically. Consumers do **not** install a system LibRaw, configure a
linker, or copy `.so`, `.dylib`, or `.dll` files manually.

For a published dependency, ordinary use is simply:

```console
dart pub add rawkit
dart run your_application.dart
```

### Web

Flutter automatically bundles RawKit's precompiled WebAssembly module and
module Worker from the package's Web-only assets. A Flutter Web consumer has no
setup command, script tag, cross-origin isolation header or Emscripten
installation to manage.

A plain Dart Web build does not bundle dependency assets. Prepare them once in
the application's `web/rawkit/` directory and configure the matching URL:

```console
dart run rawkit:prepare_library web
```

```dart
RawKit.configureWeb(assetBaseUrl: 'rawkit/');
```

Use `prepare_library all` to prepare both targets, `--force` to reinstall the
desktop source, and `--output=directory` to select a different plain Dart Web
destination.

## Usage

```dart
import 'package:rawkit/rawkit.dart';

final RawDocument raw = await RawDocument.openFile('example.CR3');
try {
  print('${raw.metadata.cameraMake} ${raw.metadata.cameraModel}');
  print(raw.metadata.lens);

  final RawDevelopSettings settings = RawDevelopSettings.defaults.copyWith(
    exposure: 0.7,
    highlights: -30,
    shadows: 25,
    vibrance: 10,
  );

  final RawImage preview = await raw.renderPreview(
    settings,
    maxWidth: 1600,
  );

  final RawImage finalImage = await raw.render(
    settings.copyWith(demosaicQuality: RawDemosaicQuality.high),
    bitDepth: RawBitDepth.uint16,
    colorSpace: RawColorSpace.srgb,
  );

  usePreviewBytes(preview.pixels8);
  useHighPrecisionSamples(finalImage.pixels16);
} finally {
  await raw.close();
}
```

`RawDocument.openMemory(bytes)` is available when the client already owns the
RAW data. RawKit transfers an ownership-safe copy into the platform worker, so
the caller can release or reuse its buffer after opening completes.

Browsers cannot open arbitrary filesystem paths, so Web applications must read
a browser `File` as bytes and use `openMemory` or `openBytes`. Calling
`openFile` in a browser reports `UnsupportedError`.

## Pixel contract

`RawImage` contains tightly packed, row-major, interleaved RGB samples with no
alpha channel:

* `RawBitDepth.uint8` : `Uint8List pixels8`;
* `RawBitDepth.uint16` : `Uint16List pixels16` in host byte order;
* `rowStride` reports bytes per row;
* `bytes` exposes a zero-copy byte view over the same Dart buffer.

LibRaw applies the camera's display orientation to rendered pixels. The source
orientation remains available as metadata and must not be applied a second
time.

The native result is always copied into a Dart-owned allocation before the
native image is freed. A `RawImage` therefore remains valid after its document
is closed and never owns a native pointer.

Output is transfer-function encoded in the selected `RawColorSpace`. The
internal cached buffer remains linear 16-bit RGB until tonal processing and
final output conversion.

## Preview caching and concurrency

Every document owns one long-lived worker isolate on native platforms or one
module Web Worker in a browser. The caller only performs message passing and
receives transferred output buffers. Commands are serialized inside the
worker, so `render` and `close` cannot race against the same decoder handle.

The preview and full-resolution caches are keyed by controls that require a
native development pass:

* white balance, temperature and tint;
* demosaic quality;
* sensor highlight recovery;
* output color-space primaries.

Exposure and all tonal/color sliders operate on the cached linear image. Slider
updates therefore avoid RAW unpacking and demosaicing. Call `clearCache()` to
release these potentially large intermediate buffers without closing the file.

Always `await raw.close()`. A Dart `Finalizer` sends a best-effort shutdown if a
document is abandoned, but deterministic cleanup is the supported lifecycle.

## Decoder and format coverage

On first use, the build hook downloads the unmodified LibRaw `0.22.2` release
archive into its project-local cache and verifies its SHA-256 before
compilation. `dart run rawkit:prepare_library desktop` offers the same verified
source installation under RawKit's `native/third_party/libraw` directory,
which is Git-ignored in a path checkout and absent from the published archive.
The Web build uses release-time Emscripten compilation, so consumers receive
only the optimized module and its small JavaScript runtime.
At runtime, `RawKit.backendInfo` and `document.backendInfo` report the actually
loaded version, making an accidental binary mismatch easy to diagnose.

The self-contained build enables LibRaw's core CR2/CR3, NEF, ARW, RAF, DNG and
other built-in decoders. Optional integrations requiring separate SDKs or
libraries—Adobe DNG SDK, RawSpeed, JPEG/JPEG XL, LCMS and zlib—are disabled.
Consequently, specialized DNG variants that depend on those integrations can
return `RawUnsupportedFileException` or `RawDecodeException`.

Custom temperature/tint conversion is an intentionally lightweight camera-WB
multiplier approximation, not an ICC/DCP color-managed workflow.

Maintainers can regenerate the published Web assets with Emscripten `4.0.15`:

```console
dart run tool/web_library_builder.dart
```

Set `RAWKIT_EMXX` or pass `--compiler=/path/to/em++` when `em++` is not on the
current `PATH`. The builder rejects a different Emscripten version.

See [architecture](docs/architecture.md), [testing](docs/testing.md), and
[third-party licensing](THIRD_PARTY_NOTICES.md) for deeper detail.

## Example and benchmark

The CLI example writes an 8-bit preview and a 16-bit final PPM without relying
on a third-party image encoder:

```console
dart run example/rawkit_example.dart input.CR3 output.ppm
```

The benchmark separates first-decode work from cached tonal updates:

```console
dart run benchmark/rawkit_benchmark.dart input.CR3
```

## Tests

```console
dart analyze
dart test
```

Unit and native smoke tests need no RAW corpus. For end-to-end coverage, point
`RAWKIT_TEST_CORPUS` at a local directory of legally usable RAW samples:

```console
RAWKIT_TEST_CORPUS=/path/to/raw-corpus dart test
```

No third-party photographs are committed to this repository.
