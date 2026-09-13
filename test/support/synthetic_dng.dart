import 'dart:convert';
import 'dart:typed_data';

/// Builds a minimal uncompressed Bayer DNG for decoder integration tests.
///
/// The image is a smooth RGGB gradient of [width] by [height] pixels with the
/// TIFF [orientation] and a `DateTime` tag set to [capturedAt]'s wall-clock
/// fields.
Uint8List buildSyntheticDng({
  required int width,
  required int height,
  required int orientation,
  required DateTime capturedAt,
}) {
  const int whiteLevel = 4095;
  final Uint8List pixels = Uint8List(width * height * 2);
  final ByteData pixelData = ByteData.sublistView(pixels);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int value = 200 + (3000 * (x + y) ~/ (width + height));
      pixelData.setUint16((y * width + x) * 2, value, Endian.little);
    }
  }

  String two(int value) => value.toString().padLeft(2, '0');
  final String dateTime =
      '${capturedAt.year.toString().padLeft(4, '0')}:${two(capturedAt.month)}:${two(capturedAt.day)} '
      '${two(capturedAt.hour)}:${two(capturedAt.minute)}:${two(capturedAt.second)}';

  final List<_TiffEntry> entries = [
    _TiffEntry.long(254, [0]),
    _TiffEntry.long(256, [width]),
    _TiffEntry.long(257, [height]),
    _TiffEntry.short(258, [16]),
    _TiffEntry.short(259, [1]),
    _TiffEntry.short(262, [32803]),
    _TiffEntry.ascii(271, 'RawKit'),
    _TiffEntry.ascii(272, 'Synthetic'),
    _TiffEntry.long(273, [0]),
    _TiffEntry.short(274, [orientation]),
    _TiffEntry.short(277, [1]),
    _TiffEntry.long(278, [height]),
    _TiffEntry.long(279, [pixels.length]),
    _TiffEntry.ascii(306, dateTime),
    _TiffEntry.short(33421, [2, 2]),
    _TiffEntry.bytes(33422, [0, 1, 1, 2]),
    _TiffEntry.bytes(50706, [1, 4, 0, 0]),
    _TiffEntry.ascii(50708, 'RawKit Synthetic'),
    _TiffEntry.long(50717, [whiteLevel]),
    _TiffEntry.signedRational(50721, [1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1]),
    _TiffEntry.rational(50728, [1, 1, 1, 1, 1, 1]),
    _TiffEntry.short(50778, [21]),
  ];

  const int headerLength = 8;
  final int directoryLength = 2 + entries.length * 12 + 4;
  int valueOffset = headerLength + directoryLength;
  final List<int> valueOffsets = [];
  for (final _TiffEntry entry in entries) {
    if (entry.data.length > 4) {
      valueOffsets.add(valueOffset);
      valueOffset += entry.data.length + entry.data.length % 2;
    } else {
      valueOffsets.add(-1);
    }
  }
  final int stripOffset = valueOffset;
  final BytesBuilder file = BytesBuilder();
  final ByteData header = ByteData(headerLength)
    ..setUint8(0, 0x49)
    ..setUint8(1, 0x49)
    ..setUint16(2, 42, Endian.little)
    ..setUint32(4, headerLength, Endian.little);
  file.add(header.buffer.asUint8List());

  final ByteData directory = ByteData(directoryLength)..setUint16(0, entries.length, Endian.little);
  for (int index = 0; index < entries.length; index++) {
    final _TiffEntry entry = entries[index];
    final int base = 2 + index * 12;
    directory
      ..setUint16(base, entry.tag, Endian.little)
      ..setUint16(base + 2, entry.type, Endian.little)
      ..setUint32(base + 4, entry.count, Endian.little);
    if (entry.tag == 273) {
      directory.setUint32(base + 8, stripOffset, Endian.little);
    } else if (valueOffsets[index] >= 0) {
      directory.setUint32(base + 8, valueOffsets[index], Endian.little);
    } else {
      for (int byte = 0; byte < entry.data.length; byte++) {
        directory.setUint8(base + 8 + byte, entry.data[byte]);
      }
    }
  }
  file.add(directory.buffer.asUint8List());

  for (final _TiffEntry entry in entries) {
    if (entry.data.length > 4) {
      file.add(entry.data);
      if (entry.data.length.isOdd) {
        file.addByte(0);
      }
    }
  }
  file.add(pixels);
  return file.takeBytes();
}

/// One little-endian TIFF directory entry and its encoded value.
final class _TiffEntry {
  _TiffEntry._(this.tag, this.type, this.count, this.data);

  /// Unsigned byte values.
  factory _TiffEntry.bytes(int tag, List<int> values) => _TiffEntry._(tag, 1, values.length, Uint8List.fromList(values));

  /// Null-terminated ASCII text.
  factory _TiffEntry.ascii(int tag, String value) {
    final Uint8List data = Uint8List.fromList([...ascii.encode(value), 0]);
    return _TiffEntry._(tag, 2, data.length, data);
  }

  /// Unsigned 16-bit values.
  factory _TiffEntry.short(int tag, List<int> values) {
    final ByteData data = ByteData(values.length * 2);
    for (int index = 0; index < values.length; index++) {
      data.setUint16(index * 2, values[index], Endian.little);
    }
    return _TiffEntry._(tag, 3, values.length, data.buffer.asUint8List());
  }

  /// Unsigned 32-bit values.
  factory _TiffEntry.long(int tag, List<int> values) {
    final ByteData data = ByteData(values.length * 4);
    for (int index = 0; index < values.length; index++) {
      data.setUint32(index * 4, values[index], Endian.little);
    }
    return _TiffEntry._(tag, 4, values.length, data.buffer.asUint8List());
  }

  /// Unsigned rationals given as numerator and denominator pairs.
  factory _TiffEntry.rational(int tag, List<int> pairs) {
    final ByteData data = ByteData(pairs.length * 4);
    for (int index = 0; index < pairs.length; index++) {
      data.setUint32(index * 4, pairs[index], Endian.little);
    }
    return _TiffEntry._(tag, 5, pairs.length ~/ 2, data.buffer.asUint8List());
  }

  /// Signed rationals given as numerator and denominator pairs.
  factory _TiffEntry.signedRational(int tag, List<int> pairs) {
    final ByteData data = ByteData(pairs.length * 4);
    for (int index = 0; index < pairs.length; index++) {
      data.setInt32(index * 4, pairs[index], Endian.little);
    }
    return _TiffEntry._(tag, 10, pairs.length ~/ 2, data.buffer.asUint8List());
  }

  /// TIFF tag number.
  final int tag;

  /// TIFF field type.
  final int type;

  /// Number of values.
  final int count;

  /// Encoded values.
  final Uint8List data;
}
