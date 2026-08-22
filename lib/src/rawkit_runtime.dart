import 'package:rawkit/src/model/raw_backend_info.dart';
import 'package:rawkit/src/native/native_backend.dart';

/// Package-level diagnostics that do not require an open RAW document.
abstract final class RawKit {
  /// Version of the native decoder source pinned by this package.
  static const String bundledNativeVersion = '0.22.2-Release';

  /// Reads diagnostics from the native code asset loaded by Dart.
  static RawBackendInfo get backendInfo => NativeRawDocument.backendInfo();
}
