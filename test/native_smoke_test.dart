import 'package:rawkit/rawkit.dart';
import 'package:test/test.dart';

void main() {
  test('loads the pinned native backend', () {
    final RawBackendInfo info = RawKit.backendInfo;

    expect(info.engine, 'LibRaw');
    expect(info.runtimeVersion, RawKit.bundledNativeVersion);
    expect(info.bundledVersion, RawKit.bundledNativeVersion);
    expect(info.apiVersion, 1);
    expect(info.isExpectedVersion, isTrue);
  });
}
