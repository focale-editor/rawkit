import 'dart:async';
import 'dart:typed_data';

import 'package:rawkit/rawkit.dart';
import 'package:rawkit/src/document/preview_scheduler.dart';
import 'package:test/test.dart';

void main() {
  RawImage image(int width) => RawImage.fromPixels(
    width: width,
    height: 1,
    channels: 3,
    bitDepth: RawBitDepth.uint8,
    colorSpace: RawColorSpace.srgb,
    pixels: Uint8List(width * 3),
  );

  Future<Object> outcome(Future<RawImage> future) => future.then<Object>((value) => value, onError: (Object error) => error);

  test('runs only the newest waiting preview', () async {
    final PreviewScheduler scheduler = PreviewScheduler();
    final Completer<RawImage> first = Completer<RawImage>();
    final List<int> started = [];

    final Future<Object> firstOutcome = outcome(
      scheduler.schedule(() {
        started.add(1);
        return first.future;
      }),
    );
    final Future<Object> secondOutcome = outcome(
      scheduler.schedule(() async {
        started.add(2);
        return image(2);
      }),
    );
    final Future<Object> thirdOutcome = outcome(
      scheduler.schedule(() async {
        started.add(3);
        return image(3);
      }),
    );

    expect(await secondOutcome, isA<RawCancelledException>());
    first.complete(image(1));
    expect((await firstOutcome as RawImage).width, 1);
    expect((await thirdOutcome as RawImage).width, 3);
    expect(started, [1, 3]);
  });

  test('a failed preview still starts the waiting one', () async {
    final PreviewScheduler scheduler = PreviewScheduler();
    final Future<Object> failed = outcome(
      scheduler.schedule(() => Future<RawImage>.error(const RawDecodeException(message: 'boom'))),
    );
    final Future<Object> next = outcome(scheduler.schedule(() async => image(4)));

    expect(await failed, isA<RawDecodeException>());
    expect((await next as RawImage).width, 4);
  });

  test('cancelWaiting fails the waiting preview', () async {
    final PreviewScheduler scheduler = PreviewScheduler();
    final Completer<RawImage> running = Completer<RawImage>();
    final Future<Object> first = outcome(scheduler.schedule(() => running.future));
    final Future<Object> waiting = outcome(scheduler.schedule(() async => image(5)));

    scheduler.cancelWaiting();
    running.complete(image(1));

    expect(await waiting, isA<RawCancelledException>());
    expect(await first, isA<RawImage>());
  });
}
