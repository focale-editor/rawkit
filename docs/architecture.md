# Architecture

RawKit keeps its public API independent from the platform decoding engine:

```text
Client application
  └─ RawDocument / models
      └─ platform worker
          ├─ linear decode caches
          ├─ tonal processor
          └─ decoder boundary
              ├─ desktop: private dart:ffi bindings
              └─ Web: Emscripten WebAssembly module
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

Opening creates a dedicated isolate on desktop or a module Web Worker in a
browser. That worker exclusively owns:

- the decoder source/parser handle;
- a half-resolution linear preview cache;
- a full-resolution linear cache;
- the last area-averaged copy of either cache;
- every synchronous decoder call.

The client communicates through request IDs. Desktop pixel results use
`TransferableTypedData`; browser results transfer their `ArrayBuffer`. Both
mechanisms move the final buffer across the worker boundary without structured
clone copying. Commands are consumed sequentially.

`RawDocument` sends at most one preview to its worker at a time. A preview
requested meanwhile waits, and a newer request replaces it; the replaced future
fails with `RawCancelledException`. Dragging a slider therefore never builds a
backlog of stale previews in the worker.

The browser implementation intentionally uses one ordinary Worker without
Emscripten threads. It therefore needs neither `SharedArrayBuffer` nor COOP/COEP
cross-origin isolation headers.

`close()` is asynchronous and idempotent. It queues behind prior work, closes
the native document, exits the worker and tears down its ports. A finalizer is
only a leak-safety fallback.

## Decoder pipeline

For each cache miss, the shim creates a fresh processing context and runs:

1. open source;
2. unpack;
3. sensor corrections;
4. white balance;
5. demosaic;
6. camera matrix;
7. linear 16-bit RGB;
8. free the processing context, keeping only LibRaw's output image;
9. copy that image into the worker cache;
10. free the output image.

The shim hands LibRaw's output image to its caller without an intermediate
copy, and releases LibRaw's working buffers before the worker copies it. Only
monochrome output is expanded into a new three-channel buffer.

Keeping a lightweight metadata context open avoids exposing LibRaw structure
layouts. Memory sources are retained by the shim because LibRaw's buffer stream
may access them during later unpacking. Workers allocate that buffer with
`rawkit_memory_allocate`, fill it once and transfer its ownership with
`rawkit_open_owned_memory`, so the RAW bytes are not copied again. On the Web,
narrow bridge functions also avoid duplicating C structure layouts in
JavaScript.

LibRaw converts most recorded capture times with `mktime()`, which depends on
the host time zone. The shim reverses that conversion, except for the CRW, Cine
and X3F formats whose times LibRaw stores unconverted, so metadata reports the
camera's wall clock on every machine.

White balance is disabled for monochrome sensors: LibRaw reports invalid camera
multipliers for them, which would otherwise crush highlight-recovery output.

Decoder output uses disabled auto-brightening and a linear transfer curve.
Exposure and editorial controls are deliberately not mapped onto unrelated
decoder parameters.

## Tonal pipeline

The desktop Dart processor and browser Worker processor produce identical
pixels. When the output is smaller than the linear image, they first average
the source area covered by each output pixel in linear light, which avoids the
aliasing of point or bilinear sampling. That copy does not depend on tonal
settings and is cached by the worker. Each pixel then goes through:

1. linear RGB;
2. exposure;
3. highlights/shadows;
4. whites/blacks;
5. contrast;
6. saturation/vibrance;
7. gamut clamp;
8. output transfer function;
9. 8/16-bit.

Highlights, shadows, whites, blacks and contrast only depend on luminance, so
that curve is sampled into a 65,537-entry table whenever those controls change.
The output transfer function is sampled once per color space. Pixels
interpolate both tables; values below 64/65,536 are computed exactly, because
power curves are too steep near black for interpolation. Results stay within
one 16-bit code of the exact formulas, several times faster.

Regional controls use smooth luminance masks and preserve RGB ratios where
possible. This is a compact photographic MVP, not a bit-for-bit Camera Raw
emulation. Keeping it separate makes the math deterministic, testable on
synthetic buffers and replaceable with SIMD/GPU processing later.

## Cache invalidation

White balance, demosaic quality, sensor highlight recovery and color-space
primaries invalidate a linear cache. Exposure, contrast, highlights, shadows,
whites, blacks, saturation and vibrance do not. Preview and full caches are
independent to avoid making an interactive preview wait for a full decode.
A preview only uses the half-resolution cache when that decode has at least as
many pixels as the requested bounds; otherwise it shares the full cache with
`render`. Replacing a decode releases the stale image, and its downscaled copy,
before the new one is allocated.
