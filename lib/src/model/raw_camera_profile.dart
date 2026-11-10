import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Immutable external DCP payload used before camera-to-working-RGB conversion.
///
/// Construction validates the bounded TIFF envelope and extracts its identity.
/// Rendering additionally validates matrices, tables, supported colour semantics
/// and the profile's declared camera model in the shared native/Web decoder.
final class RawCameraProfile {
  /// Largest accepted external profile, including its lookup tables.
  static const int maximumBytes = 8 * 1024 * 1024;

  /// Exact original profile bytes, shared through a read-only view.
  final Uint8List bytes;

  /// Content identity used by decode caches and portable application recipes.
  final String id;

  /// Profile name declared in the DCP, or a generic fallback.
  final String name;

  /// Camera model declared by the profile, absent for unrestricted profiles.
  final String? cameraModel;

  /// Reads one bounded classic TIFF/DCP profile without loading a RAW source.
  factory RawCameraProfile.fromBytes(Uint8List data) {
    if (data.length < 8 || data.length > maximumBytes) {
      throw const FormatException('Invalid DCP profile size.');
    }
    final Uint8List owned = Uint8List.fromList(data).asUnmodifiableView();
    final ByteData bytes = ByteData.sublistView(owned);
    final Endian endian;
    if (owned[0] == 0x49 && owned[1] == 0x49) {
      endian = Endian.little;
    } else if (owned[0] == 0x4d && owned[1] == 0x4d) {
      endian = Endian.big;
    } else {
      throw const FormatException('Invalid DCP byte order.');
    }
    final int magic = bytes.getUint16(2, endian);
    if (magic != 0x4352 && magic != 42) {
      throw const FormatException('Unsupported DCP header.');
    }
    final int directory = bytes.getUint32(4, endian);
    if (directory < 8 || directory > owned.length - 2) {
      throw const FormatException('Invalid DCP directory offset.');
    }
    final int count = bytes.getUint16(directory, endian);
    if (count < 1 || count > 256 || directory + 2 + count * 12 + 4 > owned.length || bytes.getUint32(directory + 2 + count * 12, endian) != 0) {
      throw const FormatException('Invalid DCP directory.');
    }
    final Set<int> tags = {};
    String? name;
    String? camera;
    for (int i = 0; i < count; i++) {
      final int entry = directory + 2 + i * 12;
      final int tag = bytes.getUint16(entry, endian);
      final int type = bytes.getUint16(entry + 2, endian);
      final int items = bytes.getUint32(entry + 4, endian);
      final int stride = switch (type) {
        1 || 2 || 7 => 1,
        3 => 2,
        4 || 9 || 11 => 4,
        5 || 10 || 12 => 8,
        _ => 0,
      };
      final int length = items * stride;
      final int offset = length <= 4 ? entry + 8 : bytes.getUint32(entry + 8, endian);
      if (!tags.add(tag) || stride == 0 || items > 2 * 1024 * 1024 || offset > owned.length || length > owned.length - offset) {
        throw const FormatException('Invalid DCP field.');
      }
      if (tag == 50936 || tag == 50708) {
        if ((type != 1 && type != 2) || length > 4096) {
          throw const FormatException('Invalid DCP identity.');
        }
        final Uint8List string = Uint8List.sublistView(owned, offset, offset + length);
        final int zero = string.indexOf(0);
        final String value = utf8.decode(zero < 0 ? string : Uint8List.sublistView(string, 0, zero)).trim();
        if (tag == 50936) {
          name = value;
        }
        if (tag == 50708) {
          camera = value.isEmpty ? null : value;
        }
      }
    }
    if (!tags.contains(50721)) {
      throw const FormatException('DCP profile has no camera colour matrix.');
    }
    return RawCameraProfile._(bytes: owned, id: sha256.convert(owned).toString(), name: name == null || name.isEmpty ? 'DCP' : name, cameraModel: camera);
  }

  /// Retains the validated immutable payload and its parsed identity.
  const RawCameraProfile._({required this.bytes, required this.id, required this.name, required this.cameraModel});

  @override
  bool operator ==(Object other) => other is RawCameraProfile && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
