# Testing RawKit

## Fast suite

Run formatting, analysis, and tests from the package root:

```console
dart format --output=none --set-exit-if-changed lib test example benchmark hook
dart analyze
dart test
```

The fast suite covers settings, RGB/RGBA pixel-buffer contracts, synthetic
tonal processing, typed failures, and native runtime/version loading. Native
build hooks run automatically.

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
- conventional and phone/camera-produced DNG.

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
