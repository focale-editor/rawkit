import 'dart:convert';
import 'dart:typed_data';

/// Builds a camera profile with independently configurable TIFF fields.
Uint8List buildSyntheticDcp({Endian endian = Endian.little, String camera = 'RawKit Synthetic', double exposure = 0, bool forward = true, Map<int, List<double>> fields = const {}}) {
  final Map<int, (int, List<num>)> tags = {
    50708: (2, [...utf8.encode(camera), 0]),
    50936: (2, [...utf8.encode('Synthetic profile'), 0]),
    50721: (10, [1, 0, 0, 0, 1, 0, 0, 0, 1]),
    50778: (3, [21]),
    if (forward) 50964: (10, [.7976749, .1351917, .0313534, .2880402, .7118741, .0000857, 0, 0, .82521]),
    51109: (10, [exposure]),
    for (final MapEntry<int, List<double>> field in fields.entries) field.key: (11, field.value),
  };
  final BytesBuilder payload = BytesBuilder();
  final int start = 8 + 2 + tags.length * 12 + 4;
  final ByteData directory = ByteData(start)
    ..setUint8(0, endian == Endian.little ? 73 : 77)
    ..setUint8(1, endian == Endian.little ? 73 : 77)
    ..setUint16(2, 0x4352, endian)
    ..setUint32(4, 8, endian)
    ..setUint16(8, tags.length, endian);
  int index = 0;
  for (final MapEntry<int, (int, List<num>)> field in tags.entries) {
    final (int type, List<num> values) = field.value;
    final int stride = type == 2
        ? 1
        : type == 3
        ? 2
        : type == 10
        ? 8
        : 4;
    final ByteData data = ByteData(values.length * stride);
    for (int i = 0; i < values.length; i++) {
      switch (type) {
        case 2:
          data.setUint8(i, values[i].toInt());
        case 3:
          data.setUint16(i * 2, values[i].toInt(), endian);
        case 10:
          data.setInt32(i * 8, (values[i] * 10000000).round(), endian);
          data.setInt32(i * 8 + 4, 10000000, endian);
        default:
          data.setFloat32(i * 4, values[i].toDouble(), endian);
      }
    }
    final int at = 10 + index++ * 12;
    directory
      ..setUint16(at, field.key, endian)
      ..setUint16(at + 2, type, endian)
      ..setUint32(at + 4, values.length, endian);
    if (data.lengthInBytes <= 4) {
      for (int i = 0; i < data.lengthInBytes; i++) {
        directory.setUint8(at + 8 + i, data.getUint8(i));
      }
    } else {
      directory.setUint32(at + 8, start + payload.length, endian);
      payload.add(data.buffer.asUint8List());
    }
  }
  return (BytesBuilder()
        ..add(directory.buffer.asUint8List())
        ..add(payload.takeBytes()))
      .takeBytes();
}
