import 'raw_types.dart';

/// Immutable controls for decoding and developing a RAW image.
final class RawDevelopSettings {
  /// Creates a set of RAW development controls.
  ///
  /// Tonal and color sliders use the inclusive range `-100` to `100`.
  /// Temperature is expressed in kelvin and tint uses a green-to-magenta
  /// scale. The temperature and tint values are used only when
  /// [whiteBalance] is [RawWhiteBalance.custom].
  const RawDevelopSettings({
    this.whiteBalance = RawWhiteBalance.camera,
    this.temperature = 6500,
    this.tint = 0,
    this.exposure = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.whites = 0,
    this.blacks = 0,
    this.saturation = 0,
    this.vibrance = 0,
    this.demosaicQuality = RawDemosaicQuality.balanced,
    this.highlightRecovery = RawHighlightRecovery.blend,
  }) : assert(temperature >= 2000 && temperature <= 50000),
       assert(tint >= -150 && tint <= 150),
       assert(exposure >= -10 && exposure <= 10),
       assert(contrast >= -100 && contrast <= 100),
       assert(highlights >= -100 && highlights <= 100),
       assert(shadows >= -100 && shadows <= 100),
       assert(whites >= -100 && whites <= 100),
       assert(blacks >= -100 && blacks <= 100),
       assert(saturation >= -100 && saturation <= 100),
       assert(vibrance >= -100 && vibrance <= 100);

  /// Neutral defaults that preserve the camera exposure and tonal response.
  static const RawDevelopSettings defaults = RawDevelopSettings();

  /// Source used to derive the white balance.
  final RawWhiteBalance whiteBalance;

  /// Custom white-balance temperature in kelvin.
  final double temperature;

  /// Custom green-to-magenta white-balance offset.
  final double tint;

  /// Exposure compensation in exposure values, from `-10` to `10`.
  final double exposure;

  /// Midtone contrast adjustment, from `-100` to `100`.
  final double contrast;

  /// Highlight-region adjustment, from `-100` to `100`.
  final double highlights;

  /// Shadow-region adjustment, from `-100` to `100`.
  final double shadows;

  /// White-point-region adjustment, from `-100` to `100`.
  final double whites;

  /// Black-point-region adjustment, from `-100` to `100`.
  final double blacks;

  /// Global color saturation adjustment, from `-100` to `100`.
  final double saturation;

  /// Saturation adjustment weighted toward initially muted colors.
  final double vibrance;

  /// Demosaicing speed and quality preference.
  final RawDemosaicQuality demosaicQuality;

  /// Sensor highlight recovery strategy.
  final RawHighlightRecovery highlightRecovery;

  /// Returns a copy with the selected controls replaced.
  RawDevelopSettings copyWith({
    RawWhiteBalance? whiteBalance,
    double? temperature,
    double? tint,
    double? exposure,
    double? contrast,
    double? highlights,
    double? shadows,
    double? whites,
    double? blacks,
    double? saturation,
    double? vibrance,
    RawDemosaicQuality? demosaicQuality,
    RawHighlightRecovery? highlightRecovery,
  }) => RawDevelopSettings(
    whiteBalance: whiteBalance ?? this.whiteBalance,
    temperature: temperature ?? this.temperature,
    tint: tint ?? this.tint,
    exposure: exposure ?? this.exposure,
    contrast: contrast ?? this.contrast,
    highlights: highlights ?? this.highlights,
    shadows: shadows ?? this.shadows,
    whites: whites ?? this.whites,
    blacks: blacks ?? this.blacks,
    saturation: saturation ?? this.saturation,
    vibrance: vibrance ?? this.vibrance,
    demosaicQuality: demosaicQuality ?? this.demosaicQuality,
    highlightRecovery: highlightRecovery ?? this.highlightRecovery,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RawDevelopSettings &&
          whiteBalance == other.whiteBalance &&
          temperature == other.temperature &&
          tint == other.tint &&
          exposure == other.exposure &&
          contrast == other.contrast &&
          highlights == other.highlights &&
          shadows == other.shadows &&
          whites == other.whites &&
          blacks == other.blacks &&
          saturation == other.saturation &&
          vibrance == other.vibrance &&
          demosaicQuality == other.demosaicQuality &&
          highlightRecovery == other.highlightRecovery;

  @override
  int get hashCode => Object.hash(
    whiteBalance,
    temperature,
    tint,
    exposure,
    contrast,
    highlights,
    shadows,
    whites,
    blacks,
    saturation,
    vibrance,
    demosaicQuality,
    highlightRecovery,
  );

  @override
  String toString() =>
      'RawDevelopSettings(whiteBalance: $whiteBalance, temperature: '
      '$temperature, tint: $tint, exposure: $exposure, contrast: $contrast, '
      'highlights: $highlights, shadows: $shadows, whites: $whites, blacks: '
      '$blacks, saturation: $saturation, vibrance: $vibrance, '
      'demosaicQuality: $demosaicQuality, highlightRecovery: '
      '$highlightRecovery)';
}
