import 'dart:math' as math;

import 'package:rawkit/src/model/raw_types.dart';

/// Fits [width] by [height] inside the maximum bounds without upscaling.
///
/// The aspect ratio is preserved and each returned dimension is at least one.
({int width, int height}) fitDimensions({
  required int width,
  required int height,
  required int maximumWidth,
  required int maximumHeight,
}) {
  final double scale = math.min(
    1,
    math.min(maximumWidth / width, maximumHeight / height),
  );
  return (
    width: math.max(1, (width * scale).round()),
    height: math.max(1, (height * scale).round()),
  );
}

/// Reports whether a half-size decode has enough pixels for a preview.
///
/// [width] and [height] are the visible sensor dimensions before
/// [orientation] is applied, while the maximum bounds apply to the displayed
/// image. Unknown dimensions keep the faster half-size decode.
bool halfSizeCoversPreview({
  required int width,
  required int height,
  required RawOrientation orientation,
  required int maximumWidth,
  required int maximumHeight,
}) {
  if (width <= 0 || height <= 0) {
    return true;
  }
  final bool swapsAxes = orientation == RawOrientation.rotate90Clockwise || orientation == RawOrientation.rotate90CounterClockwise;
  final int displayedWidth = swapsAxes ? height : width;
  final int displayedHeight = swapsAxes ? width : height;
  final ({int width, int height}) fitted = fitDimensions(
    width: displayedWidth,
    height: displayedHeight,
    maximumWidth: maximumWidth,
    maximumHeight: maximumHeight,
  );
  return fitted.width <= (displayedWidth + 1) ~/ 2 && fitted.height <= (displayedHeight + 1) ~/ 2;
}
