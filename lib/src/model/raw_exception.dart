/// Base exception for failures reported by RawKit.
class RawException implements Exception {
  /// Creates a RAW processing exception.
  const RawException({required this.message, this.code, this.cause});

  /// Native or package-specific diagnostic code, when available.
  final int? code;

  /// Human-readable description of the failure.
  final String message;

  /// Underlying error that caused this failure, when available.
  final Object? cause;

  @override
  String toString() {
    final String codeSuffix = code == null ? '' : ' (code $code)';
    return '$runtimeType: $message$codeSuffix';
  }
}

/// Indicates that the input is not a supported RAW file.
final class RawUnsupportedFileException extends RawException {
  /// Creates an unsupported-file exception.
  const RawUnsupportedFileException({required super.message, super.code});
}

/// Indicates that a RAW source could not be read.
final class RawIOException extends RawException {
  /// Creates a RAW input/output exception.
  const RawIOException({required super.message, super.code, super.cause});
}

/// Indicates that RAW decoding or development failed.
final class RawDecodeException extends RawException {
  /// Creates a RAW decoding exception.
  const RawDecodeException({required super.message, super.code, super.cause});
}

/// Indicates that native or Dart memory could not be allocated.
final class RawMemoryException extends RawException {
  /// Creates a RAW memory exception.
  const RawMemoryException({required super.message, super.code, super.cause});
}

/// Indicates that an operation is invalid for the document's lifecycle state.
final class RawStateException extends RawException {
  /// Creates a RAW lifecycle-state exception.
  const RawStateException({required super.message, super.code});
}

/// Indicates that a preview was superseded before it started rendering.
///
/// [RawDocument.renderPreview] only renders the newest waiting preview, so an
/// interactive caller can ignore this exception.
final class RawCancelledException extends RawException {
  /// Creates a preview cancellation exception.
  const RawCancelledException({required super.message});
}

/// Indicates that development or render settings are invalid.
final class RawSettingsException extends RawException {
  /// Creates a RAW settings exception.
  const RawSettingsException({required super.message});
}

/// Indicates that the bundled native backend could not be started or contacted.
final class RawBackendException extends RawException {
  /// Creates a native-backend exception.
  const RawBackendException({required super.message, super.code, super.cause});
}
