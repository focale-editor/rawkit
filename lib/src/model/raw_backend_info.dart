/// Identifies the native decoding engine bundled with the package.
final class RawBackendInfo {
  /// Creates native backend diagnostics.
  const RawBackendInfo({
    required this.engine,
    required this.runtimeVersion,
    required this.bundledVersion,
    required this.apiVersion,
  });

  /// Human-readable engine name.
  final String engine;

  /// Version reported by the loaded native engine at runtime.
  final String runtimeVersion;

  /// Engine version pinned by this package release.
  final String bundledVersion;

  /// Version of the stable RawKit C shim.
  final int apiVersion;

  /// Whether the loaded engine matches the version bundled at build time.
  bool get isExpectedVersion => runtimeVersion == bundledVersion;

  @override
  String toString() =>
      '$engine $runtimeVersion (RawKit native API $apiVersion)';
}
