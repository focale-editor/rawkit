import 'package:rawkit/src/model/raw_types.dart';

/// Camera and capture metadata parsed from a RAW document.
final class RawMetadata {
  /// Creates immutable RAW metadata.
  const RawMetadata({
    required this.cameraMake,
    required this.cameraModel,
    required this.normalizedCameraMake,
    required this.normalizedCameraModel,
    required this.lens,
    required this.lensMake,
    required this.iso,
    required this.shutterSpeed,
    required this.aperture,
    required this.focalLength,
    required this.timestamp,
    required this.orientation,
    required this.width,
    required this.height,
    required this.rawWidth,
    required this.rawHeight,
  });

  /// Camera manufacturer as recorded in the file.
  final String? cameraMake;

  /// Camera model as recorded in the file.
  final String? cameraModel;

  /// Decoder-normalized camera manufacturer.
  final String? normalizedCameraMake;

  /// Decoder-normalized camera model.
  final String? normalizedCameraModel;

  /// Lens model, when present.
  final String? lens;

  /// Lens manufacturer, when present.
  final String? lensMake;

  /// Capture sensitivity in ISO units, when present.
  final double? iso;

  /// Exposure duration in seconds, when present.
  final double? shutterSpeed;

  /// Lens aperture as an f-number, when present.
  final double? aperture;

  /// Focal length in millimetres, when present.
  final double? focalLength;

  /// Capture time as shown by the camera's clock, without a time zone.
  ///
  /// RAW files rarely record a time zone, so the camera's wall-clock fields
  /// are stored in a UTC [DateTime]: read its year, month, day, hour, minute
  /// and second directly, without calling `toLocal()`. The value does not
  /// depend on the time zone of the machine that opens the file.
  final DateTime? timestamp;

  /// Display orientation recorded by the camera.
  ///
  /// Rendered image pixels already have this orientation applied.
  final RawOrientation orientation;

  /// Visible image width before display-orientation rotation.
  final int width;

  /// Visible image height before display-orientation rotation.
  final int height;

  /// Full sensor buffer width.
  final int rawWidth;

  /// Full sensor buffer height.
  final int rawHeight;

  /// Approximate visible image size in megapixels.
  double get megapixels => width * height / 1000000;

  @override
  String toString() =>
      'RawMetadata(camera: ${cameraMake ?? ''} ${cameraModel ?? ''}, lens: '
      '${lens ?? 'unknown'}, size: ${width}x$height, rawSize: '
      '${rawWidth}x$rawHeight)';
}
