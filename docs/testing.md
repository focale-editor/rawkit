# Testing RawKit

## Fast suite

Run formatting, analysis, and tests from the package root:

```console
dart format --output=none --set-exit-if-changed lib test example benchmark hook
dart analyze
dart test
```

The fast suite covers settings, RGB/RGBA pixel-buffer contracts, synthetic
tonal processing and resampling, preview scheduling, typed failures, and native
runtime/version loading. Native build hooks run automatically.

`test/synthetic_dng_test.dart` decodes a small DNG generated in memory by
`test/support/synthetic_dng.dart`. It checks capture-time reporting, display
orientation, preview resolution selection and preview cancellation through the
real decoder, without a RAW corpus. Run it under several `TZ` values to cover
time-zone handling:

```console
TZ=America/Los_Angeles dart test test/synthetic_dng_test.dart
TZ=Asia/Tokyo dart test test/synthetic_dng_test.dart
```

## RAW corpus

Set `RAWKIT_TEST_CORPUS` to enable lifecycle and multiple-document integration
tests:

```console
RAWKIT_TEST_CORPUS=/data/rawkit-corpus dart test
```

The directory is scanned recursively for CR2, CR3, NEF, ARW, RAF, DNG, RW2,
ORF and 3FR files. Corpus tests also verify that memory input is copied before
the caller mutates its buffer. Keep a representative, legally usable set
locally or in a controlled CI artifact store. A useful matrix includes:

- Canon CR2 and CR3, including compressed variants;
- Nikon compressed and uncompressed NEF;
- Sony compressed and uncompressed ARW;
- Fujifilm Bayer and X-Trans RAF;
- conventional and phone/camera-produced DNG;
- a monochrome sensor, such as a Leica M Monochrom DNG.

[raw.pixls.us](https://raw.pixls.us) publishes CC0-licensed samples for most
cameras.

The test suite intentionally skips corpus tests when the variable is absent;
it never downloads photographs during a package build.

## Memory and native diagnostics

For release qualification, run corpus tests under platform-native leak and
sanitizer tooling. Exercise normal close, close after a decode error, repeated
close, concurrent documents, changed white balance, both cache resolutions and
both output depths.

The public benchmark is in `benchmark/rawkit_benchmark.dart`. Run it several
times with CPU scaling controlled and report the camera/file, dimensions,
platform, architecture, compiler and build mode together with timings.
