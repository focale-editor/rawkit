# Third-party notices

## LibRaw 0.22.2

The RawKit build hook fetches the unmodified LibRaw 0.22.2 source distribution
into its project-local hook cache and compiles it into the RawKit dynamic code
asset. `dart run rawkit:prepare_library desktop` can also pre-install the same
source into `native/third_party/libraw`. The downloader pins the official
archive URL and SHA-256; the downloaded tree is intentionally Git-ignored and
is not shipped in the RawKit archive published to pub.dev.

RawKit's native distribution selects LibRaw's GNU Lesser General Public
License, version 2.1 or later, option. The precompiled WebAssembly distribution
selects LibRaw's alternative CDDL licensing option. The corresponding
unmodified source remains available from the pinned upstream archive through
`prepare_library desktop`.

The authoritative notices shipped by LibRaw are preserved here:

- `third_party/libraw/COPYRIGHT`
- `third_party/libraw/LICENSE.LGPL`
- `third_party/libraw/LICENSE.CDDL`

The RawKit shim, JavaScript Worker and Dart sources are MIT-licensed. The
resulting native and WebAssembly binaries contain LibRaw, so distributors must
review and satisfy the selected LibRaw license in addition to RawKit's MIT
license. This summary is engineering documentation, not legal advice.

## OpenMP runtime

When a desktop build enables OpenMP, the build hook bundles the compiler's
OpenMP runtime next to the RawKit library:

- LLVM `libomp.so` (Linux, Clang): Apache License 2.0 with LLVM Exceptions;
- GCC `libgomp.so.1` (Linux, GCC): GNU GPL version 3 with the GCC Runtime
  Library Exception;
- Microsoft `vcomp140.dll` (Windows, MSVC): distributable under the Visual
  Studio redistributable code terms.

Distributors must satisfy the license of the runtime included in their build.

## LibRaw build configuration

No local patches are currently applied to LibRaw. The build disables optional
external integrations (Adobe DNG SDK, RawSpeed, JPEG, JPEG XL, LCMS and zlib)
so that the core decoder remains self-contained.
