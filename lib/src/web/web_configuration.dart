/// Default asset directory used by Flutter's package asset bundle.
const String defaultWebAssetBaseUrl = 'assets/packages/rawkit/assets/web/';

/// Mutable override set before the first browser document is opened.
String _webAssetBaseUrl = defaultWebAssetBaseUrl;

/// Returns the URL prefix used to start RawKit's browser Worker.
String get webAssetBaseUrl => _webAssetBaseUrl;

/// Overrides the URL prefix used by a non-Flutter Dart Web application.
void configureWebAssetBaseUrl(String assetBaseUrl) {
  final String trimmed = assetBaseUrl.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(
      assetBaseUrl,
      'assetBaseUrl',
      'The Web asset base URL must not be empty.',
    );
  }
  _webAssetBaseUrl = trimmed.endsWith('/') ? trimmed : '$trimmed/';
}
