import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:crop_your_image/crop_your_image.dart';

class ImageEditorScreen extends StatefulWidget {
  final String path;
  const ImageEditorScreen({required this.path, super.key});

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  final _controller = CropController();
  late Uint8List _imageData;
  bool _loading = true;
  bool _saving = false;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      if (!mounted) return;
      setState(() {
        _imageData = bytes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to load image: $e';
      });
    }
  }

  void _onCrop() {
    if (_loading || _saving || !_ready || _error != null) return;
    setState(() => _saving = true);
    _controller.crop();
  }

  void _onCropped(CropResult result) async {
    if (!mounted) return;
    try {
      if (result is CropSuccess) {
        final croppedImage = result.croppedImage;
        final tmp = Directory.systemTemp.path;
        final base = widget.path.split(RegExp(r'[/\\]')).last;
        final outPath =
            '$tmp/edited_${DateTime.now().microsecondsSinceEpoch}_$base';
        final f = File(outPath);
        await f.writeAsBytes(croppedImage);
        if (mounted) Navigator.pop(context, outPath);
      } else if (result is CropFailure) {
        final error = result;
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Crop failed: $error')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save image: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Image'),
        actions: [
          IconButton(
            onPressed: _loading || _saving || !_ready || _error != null
                ? null
                : _onCrop,
            icon: const Icon(Icons.check),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : Crop(
              controller: _controller,
              image: _imageData,
              onCropped: _onCropped,
              onStatusChanged: (status) {
                if (mounted) {
                  setState(() => _ready = status == CropStatus.ready);
                }
              },
              withCircleUi: false,
            ),
    );
  }
}
