import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/api_providers.dart';
import '../widgets/camera_preview_widget.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isLoading = false;
  String? _lastResponse;
  String? _promptText;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    _cameras = await availableCameras();
    if (_cameras.isEmpty) return;

    _controller = CameraController(
      _cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await _controller!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _captureAndAsk() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final prompt = _promptText?.trim();
    if (prompt == null || prompt.isEmpty) return;

    setState(() {
      _isLoading = true;
      _lastResponse = null;
    });

    try {
      final file = await _controller!.takePicture();
      final bytes = await File(file.path).readAsBytes();
      final base64Image = base64Encode(bytes);

      final api = ref.read(apiServiceProvider);
      final response = await api.chat(
        conversationId: 'camera-${DateTime.now().millisecondsSinceEpoch}',
        text: prompt,
        imageBase64List: [base64Image],
      );

      if (mounted) setState(() => _lastResponse = response.text);
    } catch (e) {
      if (mounted) setState(() => _lastResponse = 'Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Visión con cámara')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_controller != null)
              CameraPreviewWidget(controller: _controller!)
            else
              const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              ),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                hintText: '¿Qué quieres preguntarle sobre la imagen?',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => _promptText = v,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isLoading ? null : _captureAndAsk,
              icon: _isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.camera_alt_rounded),
              label: Text(_isLoading ? 'Analizando…' : 'Capturar y preguntar'),
            ),
            if (_lastResponse != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(_lastResponse!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
