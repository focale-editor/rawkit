# Third-party notices

## LibRaw 0.22.2

The RawKit build hook fetches the unmodified LibRaw 0.22.2 source distribution
into its project-local hook cache and compiles it into the RawKit dynamic code
asset. `dart run rawkit:download_library` can also pre-install the same source
into `native/third_party/libraw`. The downloader pins the official archive URL
and SHA-256; the downloaded tree is intentionally Git-ignored and is not
shipped in the RawKit archive published to pub.dev.
RawKit's distribution selects LibRaw's GNU Lesser General Public License,
version 2.1 or later, option. This selection does not remove LibRaw's alternative
CDDL licensing option from the upstream source files.

The authoritative notices shipped by LibRaw are preserved here:

- `native/third_party/libraw/COPYRIGHT`
- `native/third_party/libraw/LICENSE.LGPL`
- `native/third_party/libraw/LICENSE.CDDL`

The RawKit shim and Dart sources are MIT-licensed. The resulting native binary
contains LibRaw, so distributors must review and satisfy the selected LibRaw
license's requirements, including preserving notices, providing the applicable
license text and corresponding source, and permitting relinking or replacement
where required. This summary is engineering documentation, not legal advice.

No local patches are currently applied to LibRaw. The build disables optional
external integrations (Adobe DNG SDK, RawSpeed, JPEG, JPEG XL, LCMS and zlib)
so that the core decoder remains self-contained.
