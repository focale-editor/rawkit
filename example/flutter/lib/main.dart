import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide RawImage;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' as widgets show RawImage;
import 'package:rawkit/rawkit.dart';

/// Runs a native RAW preview using the bundled synthetic DNG.
void main() => runApp(const RawKitExample());

/// Displays an eight-bit preview and verifies a full sixteen-bit development.
class RawKitExample extends StatefulWidget {
  /// Creates the sample application.
  const RawKitExample({super.key});

  @override
  State<RawKitExample> createState() => _RawKitExampleState();
}

/// Owns the preview image and the asynchronous native decode.
class _RawKitExampleState extends State<RawKitExample> {
  /// Image owned by this widget after the native document is closed.
  ui.Image? _preview;

  /// Development outcome shown below the preview.
  String? _status;

  @override
  void initState() {
    super.initState();
    _developSample();
  }

  /// Develops the asset through RawKit's worker isolate and native library.
  Future<void> _developSample() async {
    RawDocument? document;
    ui.Image? preview;
    try {
      final ByteData asset = await rootBundle.load('assets/sample.dng');
      document = await RawDocument.openMemory(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
      );
      final RawImage image = await document.renderPreview(
        RawDevelopSettings.defaults,
        maxWidth: 64,
      );
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        image.toRgba8(),
      );
      final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: image.width,
        height: image.height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final ui.Codec codec = await descriptor.instantiateCodec();
      try {
        preview = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
      }
      final RawImage developed = await document.render(
        RawDevelopSettings.defaults,
        bitDepth: RawBitDepth.uint16,
      );
      if (mounted) {
        setState(() {
          _preview = preview;
          _status = '${developed.width} × ${developed.height} · 16-bit RGB';
        });
        preview = null;
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'RAW development failed: $error');
      }
    } finally {
      preview?.dispose();
      await document?.close();
    }
  }

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('RawKit native example')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('LibRaw ${RawKit.backendInfo.runtimeVersion}'),
              const SizedBox(height: 24),
              if (_preview != null) widgets.RawImage(image: _preview, width: 256, height: 192) else if (_status == null) const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(_status ?? 'Developing sample RAW…'),
            ],
          ),
        ),
      ),
    ),
  );
}
