# Architecture

RawKit keeps its public API independent from the native decoding engine:

```text
Client application
  └─ RawDocument / models
      └─ dedicated worker isolate
          ├─ linear decode caches
          ├─ Dart tonal processor
          └─ private dart:ffi bindings
              └─ stable rawkit C shim
                  └─ bundled LibRaw C API
```

## Public boundary

`lib/rawkit.dart` exports only documents, settings, metadata, images, enums,
exceptions and backend diagnostics. It exports no `dart:ffi` pointer, native
structure or LibRaw-specific setting. The package can therefore replace or
augment its decoder without forcing application-level API changes.

`RawImage` owns a Dart typed-data buffer. Copying at the native boundary costs
one full-image copy, but makes ownership explicit and prevents use-after-free
bugs when documents and native buffers have different lifetimes.

For 8-bit raster engines, `RawImage.toRgba8()` provides an explicit RGB-to-RGBA
copy without introducing a Flutter dependency into this package.

## Worker ownership

Opening creates a dedicated isolate. That isolate exclusively owns:

- the native source/parser handle;
- a half-resolution linear preview cache;
- a full-resolution linear cache;
- every synchronous FFI call.

The client communicates through request IDs and `SendPort`s. Pixel results use
`TransferableTypedData` so the final Dart buffer crosses the isolate boundary
without a second byte-for-byte message copy. Commands are consumed sequentially.

`close()` is asynchronous and idempotent. It queues behind prior work, closes
the native document, exits the worker and tears down its ports. A finalizer is
only a leak-safety fallback.

## Native pipeline

For each cache miss, the shim creates a fresh processing context and runs:

```text
open source → unpack → sensor corrections → white balance → demosaic
→ camera matrix → linear 16-bit RGB → copy to Dart → free native image
```

Keeping a lightweight metadata context open avoids exposing native structure
layouts. Memory sources are copied and retained by the shim because LibRaw's
buffer stream may access them during later unpacking.

Native output uses disabled auto-brightening and a linear transfer curve.
Exposure and editorial controls are deliberately not mapped onto unrelated
decoder parameters.

## Tonal pipeline

The Dart processor combines bilinear preview resampling with per-pixel work:

```text
linear RGB → exposure → shadows/highlights → whites/blacks → contrast
→ saturation/vibrance → gamut clamp → output transfer function → 8/16-bit
```

Regional controls use smooth luminance masks and preserve RGB ratios where
possible. This is a compact photographic MVP, not a bit-for-bit Camera Raw
emulation. Keeping it separate makes the math deterministic, testable on
synthetic buffers and replaceable with SIMD/GPU processing later.

## Cache invalidation

White balance, demosaic quality, sensor highlight recovery and color-space
primaries invalidate a linear cache. Exposure, contrast, highlights, shadows,
whites, blacks, saturation and vibrance do not. Preview and full caches are
independent to avoid making an interactive preview wait for a full decode.
