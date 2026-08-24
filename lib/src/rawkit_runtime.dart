import 'package:rawkit/src/model/raw_backend_info.dart';
import 'package:rawkit/src/runtime/runtime_native.dart' if (dart.library.js_interop) 'package:rawkit/src/runtime/runtime_web.dart' as runtime;

/// Package-level diagnostics that do not require an open RAW document.
abstract final class RawKit {
  /// Version of the decoder source pinned by this package.
  static const String bundledNativeVersion = '0.22.2-Release';

  /// Reads diagnostics for the decoder selected on the current platform.
  static RawBackendInfo get backendInfo => runtime.backendInfo;

  /// Overrides the browser URL containing RawKit's precompiled Web assets.
  ///
  /// Flutter Web applications do not need to call this method because package
  /// assets are discovered automatically. A Dart Web application that ran
  /// `dart run rawkit:prepare_library web` should pass the copied directory,
  /// for example `RawKit.configureWeb(assetBaseUrl: 'rawkit/')`.
  static void configureWeb({required String assetBaseUrl}) {
    runtime.configureWeb(assetBaseUrl: assetBaseUrl);
  }
}
