# RawKit

RawKit is a UI-independent Dart package for opening, inspecting and developing
camera RAW files. It bundles a pinned native decoder behind a small C shim,
runs expensive work in a dedicated isolate, caches linear RGB intermediates,
and returns pixels in Dart-owned `Uint8List` or `Uint16List` buffers.

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

## Platforms and prerequisites

RawKit targets Linux, macOS and Windows desktop. The source and hook are
structured for the host architectures supported by Dart's C toolchain. This
revision is validated on Linux x64; macOS arm64/x64 and Windows x64 are yet to be
tested.

Dart 3.13 or later and a working platform C++ compiler are required at build
time. On its first build, RawKit downloads the pinned LibRaw source into the
project's `.dart_tool` hook cache, verifies its SHA-256, and then compiles it.
No manual setup is required.

To pre-download the source, for example for an offline build that follows, run:

```console
dart run rawkit:download_library
```

The command locates the installed RawKit package and extracts LibRaw beside its
native build files. The automatic build path instead uses the project-local
hook cache. LibRaw is therefore not included in the published RawKit archive.
Re-run the command after upgrading RawKit or clearing the Pub cache.

The Dart build hook then compiles and bundles the native code asset
automatically. Consumers do **not** install a system LibRaw, configure a
linker, or copy `.so`, `.dylib`, or `.dll` files manually.

For a published dependency, ordinary use is simply:

```console
dart pub add rawkit
dart run your_application.dart
```

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
RAW data. RawKit copies memory input into the native document, so the caller can
release or reuse its buffer after opening completes.

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

Every document owns one long-lived worker isolate and a native parser handle.
The calling isolate only performs message passing and receives transferred
output buffers. Commands are serialized inside the worker, so `render` and
`close` cannot race against the same native handle.

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

## Native decoder and format coverage

On first use, the build hook downloads the unmodified LibRaw `0.22.2` release
archive into its project-local cache and verifies SHA-256
`de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa` before
compilation. `dart run rawkit:download_library` offers the same verified source
installation under RawKit's `native/third_party/libraw` directory, which is
Git-ignored in a path checkout and absent from the published archive.
At runtime, `RawKit.backendInfo` and `document.backendInfo` report the actually
loaded version, making an accidental binary mismatch easy to diagnose.

The self-contained build enables LibRaw's core CR2/CR3, NEF, ARW, RAF, DNG and
other built-in decoders. Optional integrations requiring separate SDKs or
libraries—Adobe DNG SDK, RawSpeed, JPEG/JPEG XL, LCMS and zlib—are disabled.
Consequently, specialized DNG variants that depend on those integrations can
return `RawUnsupportedFileException` or `RawDecodeException`.

Custom temperature/tint conversion is an intentionally lightweight camera-WB
multiplier approximation, not an ICC/DCP color-managed workflow.

See [architecture](docs/architecture.md), [Focale integration](docs/focale_integration.md),
[testing](doc/testing.md), and [third-party licensing](THIRD_PARTY_NOTICES.md)
for deeper detail.

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
