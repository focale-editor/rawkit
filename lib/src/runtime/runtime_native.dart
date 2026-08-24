import 'package:rawkit/src/model/raw_backend_info.dart';
import 'package:rawkit/src/native/native_backend.dart';

/// Reads diagnostics from the native code asset loaded by Dart.
RawBackendInfo get backendInfo => NativeRawDocument.backendInfo();

/// Rejects browser-only configuration on native platforms.
void configureWeb({required String assetBaseUrl}) {
  throw UnsupportedError(
    'RawKit.configureWeb is only available in browser applications.',
  );
}
