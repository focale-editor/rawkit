import 'package:rawkit/src/model/raw_develop_settings.dart';
import 'package:rawkit/src/model/raw_exception.dart';

/// Validates settings in release as well as debug builds.
void validateDevelopSettings(RawDevelopSettings settings) {
  _validateRange('temperature', settings.temperature, 2000, 50000);
  _validateRange('tint', settings.tint, -150, 150);
  _validateRange('exposure', settings.exposure, -10, 10);
  _validateRange('contrast', settings.contrast, -100, 100);
  _validateRange('highlights', settings.highlights, -100, 100);
  _validateRange('shadows', settings.shadows, -100, 100);
  _validateRange('whites', settings.whites, -100, 100);
  _validateRange('blacks', settings.blacks, -100, 100);
  _validateRange('saturation', settings.saturation, -100, 100);
  _validateRange('vibrance', settings.vibrance, -100, 100);
}

void _validateRange(String name, double value, double minimum, double maximum) {
  if (!value.isFinite || value < minimum || value > maximum) {
    throw RawSettingsException(
      message: '$name must be finite and between $minimum and $maximum; got $value.',
    );
  }
}
