import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/providers/api_providers.dart';
import '../../../core/providers/firebase_providers.dart';
import '../../../core/services/live_session_service.dart';
import '../../../core/services/tts_service.dart';
import '../widgets/camera_preview_widget.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  CameraController? _cameraCtrl;
  bool _isLoading = false;
  String? _lastResponse;
  String? _promptText;

  bool _isLive = false;
  bool _liveConnected = false;
  String _liveStatus = '';
  String _liveConversationId = '';
  Timer? _frameTimer;
  final LiveSessionService _liveSession = LiveSessionService();
  final TtsService _tts = TtsService();
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    _cameraCtrl = CameraController(cameras.first, ResolutionPreset.medium, enableAudio: false);
    await _cameraCtrl!.initialize();
    if (mounted) setState(() {});
  }

  Future<void> _captureAndAsk() async {
    if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized) return;
    final prompt = _promptText?.trim();
    if (prompt == null || prompt.isEmpty) return;
    setState(() { _isLoading = true; _lastResponse = null; });
    try {
      final file = await _cameraCtrl!.takePicture();
      final bytes = await File(file.path).readAsBytes();
      final api = ref.read(apiServiceProvider);
      final response = await api.chat(
        conversationId: 'camera-${DateTime.now().millisecondsSinceEpoch}',
        text: prompt,
        imageBase64List: [base64Encode(bytes)],
      );
      if (mounted) { setState(() => _lastResponse = response.text); _tts.speak(response.text); }
    } catch (e) {
      if (mounted) setState(() => _lastResponse = 'Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _startLive() async {
    final firebase = ref.read(firebaseServiceProvider);
    final token = await firebase.getIdToken();
    if (token == null) return;
    _liveConversationId = const Uuid().v4();
    _subs.addAll([
      _liveSession.onStateChange.listen((s) {
        if (!mounted) return;
        setState(() {
          _liveConnected = s == LiveSessionState.connected;
          _liveStatus = switch (s) {
            LiveSessionState.connected => 'En directo',
            LiveSessionState.connecting => 'Conectando…',
            LiveSessionState.error => 'Error de conexión',
            LiveSessionState.disconnected => '',
          };
        });
        if (s == LiveSessionState.connected) _startFrameTimer();
      }),
      _liveSession.onDone.listen((text) {
        if (!mounted) return;
        setState(() => _lastResponse = text);
        _tts.speak(text);
      }),
    ]);
    setState(() => _isLive = true);
    await _liveSession.connect(token);
  }

  void _startFrameTimer() {
    _frameTimer?.cancel();
    _frameTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized || !_liveConnected) return;
      try {
        final file = await _cameraCtrl!.takePicture();
        final bytes = await File(file.path).readAsBytes();
        _liveSession.sendFrame(
          conversationId: _liveConversationId,
          frameBase64: base64Encode(bytes),
          prompt: _promptText,
        );
      } catch (_) {}
    });
  }

  void _stopLive() {
    _frameTimer?.cancel();
    _frameTimer = null;
    for (final sub in _subs) { sub.cancel(); }
    _subs.clear();
    _liveSession.disconnect();
    if (mounted) setState(() { _isLive = false; _liveConnected = false; _liveStatus = ''; });
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _frameTimer = null;
    for (final sub in _subs) { sub.cancel(); }
    _subs.clear();
    _liveSession.disconnect();
    _liveSession.dispose();
    _cameraCtrl?.dispose();
    _tts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isLive ? 'Modo en directo' : 'Visión con cámara'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(_tts.isEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded),
            onPressed: () => setState(() => _tts.toggle()),
            tooltip: 'Voz del agente',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_cameraCtrl != null)
              Stack(
                alignment: Alignment.topRight,
                children: [
                  CameraPreviewWidget(controller: _cameraCtrl!),
                  if (_isLive && _liveStatus.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.all(8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _liveConnected ? colors.error : colors.outline,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(_liveStatus, style: const TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                ],
              )
            else
              const SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
            const SizedBox(height: 16),
            TextField(
              decoration: InputDecoration(
                hintText: _isLive ? 'Instrucción para el agente en directo…' : '¿Qué quieres preguntarle sobre la imagen?',
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => _promptText = v,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_isLoading || _isLive) ? null : _captureAndAsk,
                    icon: _isLoading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.camera_alt_rounded),
                    label: Text(_isLoading ? 'Analizando…' : 'Capturar y preguntar'),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: _isLive ? _stopLive : _startLive,
                  style: _isLive
                      ? FilledButton.styleFrom(backgroundColor: colors.errorContainer, foregroundColor: colors.onErrorContainer)
                      : null,
                  child: Icon(_isLive ? Icons.stop_rounded : Icons.play_arrow_rounded),
                ),
              ],
            ),
            if (_lastResponse != null) ...[
              const SizedBox(height: 16),
              Card(child: Padding(padding: const EdgeInsets.all(14), child: Text(_lastResponse!))),
            ],
          ],
        ),
      ),
    );
  }
}
