import 'package:rawkit/src/model/raw_backend_info.dart';
import 'package:rawkit/src/web/web_configuration.dart';

/// Reports the WebAssembly decoder bundled as a package asset.
RawBackendInfo get backendInfo => const RawBackendInfo(
  engine: 'LibRaw WebAssembly',
  runtimeVersion: '0.22.2-Release',
  bundledVersion: '0.22.2-Release',
  apiVersion: 1,
);

/// Selects a custom browser asset location.
void configureWeb({required String assetBaseUrl}) {
  configureWebAssetBaseUrl(assetBaseUrl);
}
