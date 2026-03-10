import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' show Amplitude;
import 'package:geolocator/geolocator.dart';
import 'package:torch_light/torch_light.dart';
import 'package:vibration/vibration.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/providers/firebase_providers.dart';
import '../../../core/services/audio_service.dart';
import '../../../core/services/background_service.dart';
import '../../../core/services/live_session_service.dart';
import '../../../core/services/pcm_audio_service.dart';

enum AssistantState { inactive, connecting, listening, speaking }

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin {
  
  static const String _settingsFileName = 'conversation_settings.json';
  
  static const double _defaultVadThresholdDb = -68.0;
  static const double _defaultBargeInThresholdDb = -10.0;
  static const int _defaultSilenceMs = 650;
  static const int _defaultAgentSpeechGraceMs = 900;

  CameraController? _cameraCtrl;
  List<CameraDescription> _availableCameras = const [];
  CameraLensDirection _selectedLensDirection = CameraLensDirection.front;

  final LiveSessionService _liveSession = LiveSessionService();
  final AudioService _audio = AudioService();
  final PcmAudioService _pcmAudio = PcmAudioService();
  final ImagePicker _picker = ImagePicker();

  AssistantState _state = AssistantState.inactive;
  double _vadThresholdDb = _defaultVadThresholdDb;
  double _bargeInThresholdDb = _defaultBargeInThresholdDb;
  int _silenceMs = _defaultSilenceMs;
  int _agentSpeechGraceMs = _defaultAgentSpeechGraceMs;
  String _conversationProfile = 'Equilibrado';

  StreamSubscription<String>? _audioStreamSub;
  StreamSubscription<Amplitude>? _amplitudeSub;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _agentSpeechIdleTimer;
  DateTime? _bargeInStartedAt;
  DateTime? _agentSpeechStartedAt;
  bool _agentAudioActive = false;
  bool _isVibrating = false;
  bool _showCameraPreview = false;
  Timer? _hideCameraTimer;
  Map<String, dynamic>? _structuredContent;
  Map<String, dynamic>? _selectedItem;

  // Captura manual con cámara trasera
  bool _awaitingManualCapture = false;
  Completer<String?>? _manualCaptureCompleter;
  Timer? _manualCaptureTimer;
  int _manualCaptureCountdown = 30;

  bool get _bargeInEnabled => _conversationProfile != 'Evitar cortes';
  
  // Para la nueva funcionalidad de galería
  XFile? _selectedGalleryImage;

  late final AnimationController _pulseCtrl;
  late final AnimationController _waveCtrl;
  late final Animation<double> _pulseAnim;
  late final Animation<double> _waveAnim;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _initCamera();
    unawaited(_loadConversationSettings());
    
    _liveSession.onDisplayContent.listen((data) {
      if (mounted) setState(() => _structuredContent = data);
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _cameraCtrl?.dispose();
    _audio.dispose();
    _pcmAudio.dispose();
    _agentSpeechIdleTimer?.cancel();
    _hideCameraTimer?.cancel();
    for (final sub in _subs) sub.cancel();
    super.dispose();
  }

  void _initAnimations() {
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _waveCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.88, end: 1.12).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _waveAnim = Tween<double>(begin: 0.3, end: 1.0).animate(CurvedAnimation(parent: _waveCtrl, curve: Curves.easeInOut));
  }

  Future<void> _initCamera() async {
    _availableCameras = await availableCameras();
    if (_availableCameras.isEmpty) return;
    final selectedCamera = _findCameraForLens(_selectedLensDirection) ?? _availableCameras.first;
    _selectedLensDirection = selectedCamera.lensDirection;
    _cameraCtrl = CameraController(selectedCamera, ResolutionPreset.low, enableAudio: false);
    await _cameraCtrl!.initialize();
    if (mounted) setState(() {});
  }

  CameraDescription? _findCameraForLens(CameraLensDirection lensDirection) {
    for (final camera in _availableCameras) { if (camera.lensDirection == lensDirection) return camera; }
    return null;
  }

  Future<void> _switchCamera(CameraLensDirection lensDirection) async {
    if (_selectedLensDirection == lensDirection) return;
    final selectedCamera = _findCameraForLens(lensDirection);
    if (selectedCamera == null) return;
    final nextController = CameraController(selectedCamera, ResolutionPreset.low, enableAudio: false);
    try {
      await nextController.initialize();
      final old = _cameraCtrl;
      _cameraCtrl = nextController;
      _selectedLensDirection = lensDirection;
      if (mounted) setState(() {});
      await old?.dispose();
    } catch (_) { await nextController.dispose(); }
  }

  Future<void> _startSession() async {
    try {
      if (!await _audio.hasPermission) { _showMessage('Necesito permiso de microfono'); return; }
      final token = await ref.read(firebaseServiceProvider).getIdToken();
      if (token == null) { _showMessage('No se pudo autenticar'); return; }

      await _pcmAudio.init();
      _subs.addAll([
        _liveSession.onStateChange.listen((s) {
          if (!mounted) return;
          if (s == LiveSessionState.connecting) _setStateIfMounted(AssistantState.connecting);
          else if (s == LiveSessionState.connected) _startStreaming();
          else if (s == LiveSessionState.error) { _stopSession(); _showMessage('Error de conexión'); }
          else if (s == LiveSessionState.disconnected) { if (_state != AssistantState.inactive) _stopSession(); }
        }),
        _liveSession.onAudioChunk.listen((audioChunk) {
          if (!mounted) return;
          _markAgentSpeechActive();
          _setStateIfMounted(AssistantState.speaking);
          _pcmAudio.feedBase64(audioChunk['data'] ?? '', mimeType: audioChunk['mimeType']);
        }),
        _liveSession.onInterruption.listen((_) { if (mounted) _stopSpeaking(); }),
        _liveSession.onDone.listen((_) { if (mounted) _handleAgentSpeechEnded(); }),
        _liveSession.onFrameRequest.listen((data) async {
          if (!mounted) return;
          final source = data['source'] as String? ?? 'camera';
          if (source == 'camera') {
            // Cambiar a cámara trasera, mostrar preview y esperar captura manual
            await _switchCamera(CameraLensDirection.back);
            setState(() {
              _showCameraPreview = true;
              _awaitingManualCapture = true;
              _manualCaptureCountdown = 30;
            });
            _manualCaptureCompleter = Completer<String?>();
            // Countdown de 30s
            _manualCaptureTimer?.cancel();
            _manualCaptureTimer = Timer.periodic(const Duration(seconds: 1), (t) {
              if (!mounted) { t.cancel(); return; }
              setState(() => _manualCaptureCountdown--);
              if (_manualCaptureCountdown <= 0) {
                t.cancel();
                _cancelManualCapture();
              }
            });
            final frame = await _manualCaptureCompleter!.future;
            // Volver a cámara frontal tras capturar
            unawaited(_switchCamera(CameraLensDirection.front));
            if (frame != null) _liveSession.sendFrame(frameBase64: frame);
          } else {
            final frame = await _captureFrame(source: source);
            if (frame != null) _liveSession.sendFrame(frameBase64: frame);
          }
        }),
        _liveSession.onCommand.listen((cmd) { if (mounted) _handleHardwareCommand(cmd); }),
        _liveSession.onError.listen((msg) { _showMessage('Asistente: $msg'); }),
      ]);

      await hiBOBBackgroundService.startForeground();
      await _liveSession.connect(token);
      unawaited(_startLocationUpdates());
    } catch (e) { _stopSession(); _showMessage('Error al iniciar: $e'); }
  }

  void _startStreaming() {
    _setStateIfMounted(AssistantState.listening);
    _audioStreamSub?.cancel();
    _amplitudeSub?.cancel();
    unawaited(_audio.startStreamingRecording(intervalMs: 200));
    _amplitudeSub = _audio.amplitudeStream().listen(_handleAmplitudeSample);
    _audioStreamSub = _audio.audioChunkStream.listen((base64Chunk) {
      if (_liveSession.state == LiveSessionState.connected && _shouldForwardAudioChunk()) {
        _liveSession.sendAudioChunk(audioBase64: base64Chunk);
      }
    });
  }

  bool _shouldForwardAudioChunk() {
    // Si el dispositivo está vibrando o el agente está hablando (en perfil "Evitar cortes"),
    // bloqueamos el envío de audio para evitar auto-interrupciones accidentales.
    if (_isVibrating) return false;
    if (_agentAudioActive && _conversationProfile == 'Evitar cortes') return false;
    return true;
  }

  void _handleAmplitudeSample(Amplitude amp) {
    if (!_agentAudioActive || _isVibrating) return;
    final now = DateTime.now();
    final graceElapsed = _agentSpeechStartedAt != null && now.difference(_agentSpeechStartedAt!).inMilliseconds >= _agentSpeechGraceMs;
    if (!graceElapsed) return;
    if (amp.current >= _bargeInThresholdDb) {
      _bargeInStartedAt ??= now;
      if (now.difference(_bargeInStartedAt!).inMilliseconds >= 900 && _bargeInEnabled) _stopSpeaking();
    } else { _bargeInStartedAt = null; }
  }

  void _markAgentSpeechActive() {
    _agentSpeechStartedAt ??= DateTime.now();
    _agentAudioActive = true;
    _agentSpeechIdleTimer?.cancel();
    _agentSpeechIdleTimer = Timer(const Duration(milliseconds: 7000), _handleAgentSpeechEnded);
  }

  void _handleAgentSpeechEnded() {
    _agentSpeechIdleTimer?.cancel();
    _agentAudioActive = false;
    if (_state != AssistantState.inactive) _setStateIfMounted(AssistantState.listening);
  }

  Future<void> _startLocationUpdates() async {
    try {
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium));
      _liveSession.sendLocation(latitude: pos.latitude, longitude: pos.longitude, accuracy: pos.accuracy);
    } catch (_) {}
  }

  void _handleHardwareCommand(Map<String, dynamic> cmd) async {
    final action = cmd['action'] as String?;
    if (action == 'flashlight') {
      final enabled = cmd['enabled'] as bool? ?? false;
      try { if (enabled) await TorchLight.enableTorch(); else await TorchLight.disableTorch(); } catch (_) {}
    } else if (action == 'switch_camera') {
      await _switchCamera(cmd['direction'] == 'front' ? CameraLensDirection.front : CameraLensDirection.back);
    } else if (action == 'vibrate') {
      if (await Vibration.hasVibrator()) {
        setState(() => _isVibrating = true);
        Vibration.vibrate(duration: 100);
        Future.delayed(const Duration(milliseconds: 250), () {
          if (mounted) setState(() => _isVibrating = false);
        });
      }
    } else if (action == 'open_gallery') {
      _openGalleryPicker();
    }
  }

  Future<void> _openGalleryPicker() async {
    try {
      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        setState(() => _selectedGalleryImage = image);
        _showImageReviewDialog();
      }
    } catch (e) { _showMessage('Error abriendo galería: $e'); }
  }

  void _showImageReviewDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Analizar captura', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(File(_selectedGalleryImage!.path), height: 200, fit: BoxFit.contain),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () { setState(() => _selectedGalleryImage = null); Navigator.pop(context); },
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24)),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () { _sendImageToAssistant(); Navigator.pop(context); },
                      style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
                      child: const Text('Aceptar'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendImageToAssistant() async {
    if (_selectedGalleryImage == null) return;
    try {
      final bytes = await File(_selectedGalleryImage!.path).readAsBytes();
      _liveSession.sendFrame(
        frameBase64: base64Encode(bytes),
        prompt: 'El usuario ha seleccionado esta captura de su galería para que la analices. Busca URLs sospechosas, estafas o contenido importante.',
      );
      _showMessage('Imagen enviada a hiBOB...');
      setState(() => _selectedGalleryImage = null);
    } catch (e) { _showMessage('Error enviando imagen: $e'); }
  }

  Future<String?> _captureFrame({String source = 'camera'}) async {
    try {
      if (source == 'gallery') {
        final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
        if (image == null) return null;
        final bytes = await File(image.path).readAsBytes();
        return base64Encode(bytes);
      }

      if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized) return null;
      final file = await _cameraCtrl!.takePicture();
      final bytes = await File(file.path).readAsBytes();
      return base64Encode(bytes);
    } catch (e) { return null; }
  }

  Future<void> _triggerManualCapture() async {
    if (!_awaitingManualCapture || _manualCaptureCompleter == null) return;
    _manualCaptureTimer?.cancel();
    final frame = await _captureFrame(source: 'camera');
    setState(() { _awaitingManualCapture = false; _showCameraPreview = false; });
    if (!_manualCaptureCompleter!.isCompleted) _manualCaptureCompleter!.complete(frame);
  }

  void _cancelManualCapture() {
    _manualCaptureTimer?.cancel();
    setState(() { _awaitingManualCapture = false; _showCameraPreview = false; });
    if (_manualCaptureCompleter != null && !_manualCaptureCompleter!.isCompleted) {
      _manualCaptureCompleter!.complete(null);
    }
  }

  void _stopSpeaking() { _pcmAudio.stop(); _handleAgentSpeechEnded(); }

  void _stopSession() {
    _audioStreamSub?.cancel();
    _amplitudeSub?.cancel();
    _agentSpeechIdleTimer?.cancel();
    _showCameraPreview = false;
    unawaited(_audio.stopRecording());
    for (final sub in _subs) sub.cancel();
    _subs.clear();
    _pcmAudio.stop();
    _liveSession.disconnect();
    _setStateIfMounted(AssistantState.inactive);
    unawaited(hiBOBBackgroundService.stop());
  }

  void _setStateIfMounted(AssistantState newState) {
    if (!mounted || _state == newState) return;
    setState(() => _state = newState);
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _toggleFlashLocally() async {
    if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized) return;
    final newMode = _cameraCtrl!.value.flashMode == FlashMode.torch ? FlashMode.off : FlashMode.torch;
    await _cameraCtrl!.setFlashMode(newMode);
    setState(() {});
  }

  Future<void> _signOut() async { _stopSession(); await ref.read(firebaseServiceProvider).signOut(); }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _buildGeminiAura(colors),
          _buildTopOverlay(),
          _buildCameraPreview(size),
          if (_structuredContent != null) _buildContentOverlay(size, colors),
          _buildBottomControlBar(colors),
        ],
      ),
    );
  }

  Widget _buildGeminiAura(ColorScheme colors) {
    Color auraColor = _state == AssistantState.listening ? colors.secondary.withValues(alpha: 0.3) : (_state == AssistantState.speaking ? Colors.cyanAccent.withValues(alpha: 0.38) : colors.primary.withValues(alpha: 0.14));
    return AnimatedContainer(duration: const Duration(milliseconds: 800), decoration: BoxDecoration(gradient: RadialGradient(colors: [auraColor, Colors.black87, Colors.black], center: Alignment.center, radius: 1.2)));
  }

  Widget _buildCameraPreview(Size size) {
    return IgnorePointer(
      ignoring: !_showCameraPreview,
      child: AnimatedOpacity(
        opacity: _showCameraPreview ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 600),
        child: Center(
          child: AnimatedScale(
            scale: _showCameraPreview ? 1.0 : 0.85,
            duration: const Duration(milliseconds: 600),
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Container(
                  width: size.width * 0.92, height: size.height * 0.62,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(32), border: Border.all(color: Colors.white24, width: 2), boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 30)]),
                  clipBehavior: Clip.antiAlias,
                  child: (_cameraCtrl != null && _cameraCtrl!.value.isInitialized) ? CameraPreview(_cameraCtrl!) : Container(color: Colors.grey[900], child: const Icon(Icons.camera_alt, color: Colors.white24, size: 64)),
                ),
                if (_awaitingManualCapture)
                  Positioned(
                    bottom: 20,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Enfoca y captura · $_manualCaptureCountdown s', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: _cancelManualCapture,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24), border: Border.all(color: Colors.white24)),
                                child: const Text('Cancelar', style: TextStyle(color: Colors.white60, fontSize: 14)),
                              ),
                            ),
                            const SizedBox(width: 16),
                            GestureDetector(
                              onTap: _triggerManualCapture,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.camera_alt, color: Colors.black, size: 20),
                                    SizedBox(width: 8),
                                    Text('Capturar', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopOverlay() {
    return Positioned(top: 40, left: 20, right: 20, child: Row(children: [
      _StatusBadge(state: _state), 
      const Spacer(),
      _CircleButton(icon: Icons.tune_rounded, onTap: _openFineTuningPanel),
      const SizedBox(width: 10),
      _CircleButton(icon: Icons.photo_library_rounded, onTap: _openGalleryPicker),
      const SizedBox(width: 10),
      _CircleButton(icon: _cameraCtrl?.value.flashMode == FlashMode.torch ? Icons.flashlight_on : Icons.flashlight_off, onTap: _toggleFlashLocally),
      const SizedBox(width: 10),
      _CircleButton(icon: Icons.logout_rounded, onTap: _signOut),
    ]));
  }

  Widget _buildBottomControlBar(ColorScheme colors) {
    return Positioned(left: 20, right: 20, bottom: 34, child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12), decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(40), border: Border.all(color: Colors.white10), boxShadow: [BoxShadow(color: colors.primary.withValues(alpha: 0.15), blurRadius: 24)]), child: Row(children: [
      _buildAiActionButton(colors), const Spacer(), _buildStateSpecificContent(colors), const SizedBox(width: 12),
    ])));
  }

  Widget _buildAiActionButton(ColorScheme colors) {
    final isInactive = _state == AssistantState.inactive;
    final isConnecting = _state == AssistantState.connecting;
    return GestureDetector(
      onTap: isInactive ? _startSession : _stopSession,
      child: Container(
        width: 56, height: 56,
        decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: isConnecting ? [Colors.grey[700]!, Colors.grey[600]!] : [colors.primary, colors.secondary])),
        child: isConnecting ? const Padding(padding: EdgeInsets.all(16.0), child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white)) : Icon(isInactive ? Icons.auto_awesome : Icons.stop_rounded, color: Colors.white, size: 28),
      ),
    );
  }

  Widget _buildStateSpecificContent(ColorScheme colors) {
    if (_state == AssistantState.connecting) return const Text('Conectando…', style: TextStyle(color: Colors.white54, fontSize: 14));
    if (_state == AssistantState.listening) return ScaleTransition(scale: _pulseAnim, child: const Icon(Icons.hearing_rounded, color: Colors.white70, size: 30));
    if (_state == AssistantState.speaking) return _SpeakingWave(anim: _waveAnim, colors: colors);
    return const Icon(Icons.keyboard_voice_rounded, color: Colors.white54, size: 24);
  }

  Widget _buildContentOverlay(Size size, ColorScheme colors) {
    final type = _structuredContent!['type'] as String? ?? 'detail';
    void onClose() => setState(() { _structuredContent = null; _selectedItem = null; });

    if (type == 'vt_report') {
      return _VtReportOverlay(
        title: _structuredContent!['title'] as String? ?? '',
        vtData: _structuredContent!['vtData'] as Map<String, dynamic>?,
        onClose: onClose,
      );
    }
    if (type == 'ip_report') {
      return _IpReportOverlay(
        title: _structuredContent!['title'] as String? ?? '',
        ipData: _structuredContent!['ipData'] as Map<String, dynamic>?,
        onClose: onClose,
      );
    }
    if (type == 'domain_report') {
      return _DomainReportOverlay(
        title: _structuredContent!['title'] as String? ?? '',
        domainData: _structuredContent!['domainData'] as Map<String, dynamic>?,
        onClose: onClose,
      );
    }
    if (type == 'password_check') {
      return _PasswordCheckOverlay(
        title: _structuredContent!['title'] as String? ?? '',
        passwordData: _structuredContent!['passwordData'] as Map<String, dynamic>?,
        onClose: onClose,
      );
    }
    if (type == 'password_generated') {
      return _PasswordGeneratedOverlay(
        passwordData: _structuredContent!['passwordData'] as Map<String, dynamic>?,
        onClose: onClose,
      );
    }
    if (type == 'qr_scan' || type == 'file_scan') {
      return _ScanProgressOverlay(
        title: _structuredContent!['title'] as String? ?? '',
        items: _structuredContent!['items'] as List<dynamic>? ?? [],
        onClose: onClose,
      );
    }

    // Panel genérico para otros tipos de contenido
    final isDetail = _selectedItem != null;
    final title = isDetail ? (_selectedItem!['title'] as String? ?? '') : (_structuredContent!['title'] as String? ?? '');
    final items = _structuredContent!['items'] as List<dynamic>? ?? [];
    return Center(child: Container(
      width: size.width * 0.88, height: size.height * 0.55,
      margin: const EdgeInsets.only(bottom: 60),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(32), border: Border.all(color: Colors.white10), boxShadow: [const BoxShadow(color: Colors.black54, blurRadius: 40)]),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        _buildPanelHeader(title, isDetail),
        Expanded(child: isDetail ? _buildDetailView(_selectedItem!, colors) : _buildListView(items, colors)),
      ]),
    ));
  }

  Widget _buildPanelHeader(String title, bool isDetail) {
    return Container(padding: const EdgeInsets.all(20), child: Row(children: [
      if (isDetail) IconButton(icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 18), onPressed: () => setState(() => _selectedItem = null)),
      Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
      IconButton(icon: const Icon(Icons.close, color: Colors.white70), onPressed: () => setState(() { _structuredContent = null; _selectedItem = null; })),
    ]));
  }

  Widget _buildListView(List<dynamic> items, ColorScheme colors) {
    return ListView.separated(padding: const EdgeInsets.symmetric(horizontal: 16), itemCount: items.length, separatorBuilder: (_, __) => const SizedBox(height: 12), itemBuilder: (context, index) {
      final item = items[index] as Map<String, dynamic>;
      return InkWell(onTap: () => setState(() => _selectedItem = item), borderRadius: BorderRadius.circular(16), child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(16)), child: Row(children: [
        if (item['imageUrl'] != null) ClipRRect(borderRadius: BorderRadius.circular(8), child: item['imageUrl'].toString().startsWith('data:') ? Image.memory(base64Decode(item['imageUrl'].toString().split(',').last), width: 50, height: 50, fit: BoxFit.cover) : Image.network(item['imageUrl'].toString(), width: 50, height: 50, fit: BoxFit.cover, errorBuilder: (_,__,___) => const Icon(Icons.image, color: Colors.white24))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item['title'] ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), Text(item['description'] ?? '', style: const TextStyle(color: Colors.white60, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis)]))
      ])));
    });
  }

  Widget _buildDetailView(Map<String, dynamic> item, ColorScheme colors) {
    final imgUrl = item['imageUrl'] as String?;
    return SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (imgUrl != null) ClipRRect(borderRadius: BorderRadius.circular(16), child: imgUrl.startsWith('data:') ? Image.memory(base64Decode(imgUrl.split(',').last), width: double.infinity, height: 200, fit: BoxFit.contain) : Image.network(imgUrl, width: double.infinity, height: 150, fit: BoxFit.cover)),
      const SizedBox(height: 16),
      Text(item['description'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4)),
    ]));
  }

  void _applyConversationProfile(String profile) {
    _conversationProfile = profile;
    if (profile == 'Evitar cortes') { 
      _vadThresholdDb = -66; 
      _agentSpeechGraceMs = 1500;
    } else if (profile == 'Interrupcion facil') { 
      _vadThresholdDb = -68; 
      _bargeInThresholdDb = -18;
      _agentSpeechGraceMs = 600;
    } else { 
      _vadThresholdDb = _defaultVadThresholdDb; 
      _bargeInThresholdDb = _defaultBargeInThresholdDb;
      _agentSpeechGraceMs = _defaultAgentSpeechGraceMs;
    }
  }

  void _openFineTuningPanel() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(builder: (context, modalSetState) {
          void updateSettings(VoidCallback update) { modalSetState(update); setState(() {}); unawaited(_persistConversationSettings()); }
          return SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 28), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Ajuste de Conversación', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _CalibrationChip(label: 'Equilibrado', isSelected: _conversationProfile == 'Equilibrado', onTap: () => updateSettings(() => _applyConversationProfile('Equilibrado'))),
              _CalibrationChip(label: 'Evitar cortes', isSelected: _conversationProfile == 'Evitar cortes', onTap: () => updateSettings(() => _applyConversationProfile('Evitar cortes'))),
              _CalibrationChip(label: 'Interrupción fácil', isSelected: _conversationProfile == 'Interrupcion facil', onTap: () => updateSettings(() => _applyConversationProfile('Interrupcion facil'))),
            ]),
            const SizedBox(height: 24),
            _SettingSlider(label: 'Sensibilidad VAD', valueLabel: '${_vadThresholdDb.toInt()} dB', value: _vadThresholdDb, min: -80, max: -30, divisions: 50, onChanged: (v) => updateSettings(() => _vadThresholdDb = v)),
            _SettingSlider(label: 'Umbral Interrupción', valueLabel: '${_bargeInThresholdDb.toInt()} dB', value: _bargeInThresholdDb, min: -50, max: 0, divisions: 50, onChanged: (v) => updateSettings(() => _bargeInThresholdDb = v)),
          ])));
        });
      },
    );
  }

  Future<File> _settingsFile() async { final dir = await getApplicationSupportDirectory(); return File('${dir.path}/$_settingsFileName'); }
  Future<void> _loadConversationSettings() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      setState(() { 
        _conversationProfile = json['conversationProfile'] ?? 'Equilibrado'; 
        _vadThresholdDb = (json['vadThresholdDb'] ?? _defaultVadThresholdDb).toDouble(); 
        _bargeInThresholdDb = (json['bargeInThresholdDb'] ?? _defaultBargeInThresholdDb).toDouble();
      });
    } catch (_) {}
  }
  Future<void> _persistConversationSettings() async {
    try { await (await _settingsFile()).writeAsString(jsonEncode({
      'conversationProfile': _conversationProfile, 
      'vadThresholdDb': _vadThresholdDb,
      'bargeInThresholdDb': _bargeInThresholdDb,
    })); } catch (_) {}
  }
}

class _CalibrationChip extends StatelessWidget {
  final String label; final bool isSelected; final VoidCallback onTap;
  const _CalibrationChip({required this.label, required this.isSelected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: isSelected ? Colors.white12 : Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(20), border: Border.all(color: isSelected ? Colors.white70 : Colors.white12)), child: Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 12))));
  }
}

class _SettingSlider extends StatelessWidget {
  final String label, valueLabel; final double value, min, max; final int divisions; final ValueChanged<double> onChanged;
  const _SettingSlider({required this.label, required this.valueLabel, required this.value, required this.min, required this.max, required this.divisions, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14))), Text(valueLabel, style: const TextStyle(color: Colors.white70, fontSize: 12))]),
      Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged, activeColor: Colors.white70, inactiveColor: Colors.white12),
    ]);
  }
}

class _StatusBadge extends StatelessWidget {
  final AssistantState state;
  const _StatusBadge({required this.state});
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      AssistantState.inactive => ('Inactivo', Colors.white38),
      AssistantState.connecting => ('Conectando…', Colors.amber),
      AssistantState.listening => ('Escuchando', Colors.greenAccent),
      AssistantState.speaking => ('Hablando', Colors.cyanAccent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon; final VoidCallback onTap;
  const _CircleButton({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: 0.4)),
        child: Icon(icon, color: Colors.white70, size: 20),
      ),
    );
  }
}

// ─── VirusTotal Report Overlay ────────────────────────────────────────────────

class _VtReportOverlay extends StatefulWidget {
  final String title;
  final Map<String, dynamic>? vtData;
  final VoidCallback onClose;
  const _VtReportOverlay({required this.title, required this.vtData, required this.onClose});
  @override
  State<_VtReportOverlay> createState() => _VtReportOverlayState();
}

class _VtReportOverlayState extends State<_VtReportOverlay> with TickerProviderStateMixin {
  late final AnimationController _scanCtrl;
  late final AnimationController _revealCtrl;
  late final AnimationController _pulseCtrl;
  late final Animation<double> _scanAnim;
  late final Animation<double> _revealAnim;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _scanCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat();
    _revealCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
    _scanAnim = CurvedAnimation(parent: _scanCtrl, curve: Curves.linear);
    _revealAnim = CurvedAnimation(parent: _revealCtrl, curve: Curves.easeOutCubic);
    _pulseAnim = CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut);
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _revealCtrl.forward();
    });
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _revealCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  Color get _threatColor {
    final level = widget.vtData?['threatLevel'] as String? ?? 'clean';
    return switch (level) {
      'critical' => const Color(0xFFFF1744),
      'dangerous' => const Color(0xFFFF6D00),
      'suspicious' => const Color(0xFFFFD600),
      _ => const Color(0xFF00E676),
    };
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final vtData = widget.vtData;
    final isDanger = vtData?['isDanger'] as bool? ?? false;
    final level = vtData?['threatLevel'] as String? ?? 'clean';

    return FadeTransition(
      opacity: _revealAnim,
      child: Center(
        child: Container(
          width: size.width * 0.92,
          margin: const EdgeInsets.only(bottom: 50),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: _threatColor.withValues(alpha: 0.6), width: 1.5),
            boxShadow: [BoxShadow(color: _threatColor.withValues(alpha: 0.25), blurRadius: 40, spreadRadius: 4)],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildScanHeader(isDanger, level),
                if (vtData != null) ...[
                  _buildUrlBar(vtData),
                  _buildScoreSection(vtData),
                  _buildEngineBreakdown(vtData),
                ] else
                  _buildUnavailable(),
                _buildCloseButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScanHeader(bool isDanger, String level) {
    final label = switch (level) {
      'critical' => 'AMENAZA CRÍTICA',
      'dangerous' => 'AMENAZA DETECTADA',
      'suspicious' => 'SOSPECHOSO',
      _ => 'ENLACE SEGURO',
    };
    return AnimatedBuilder(
      animation: _scanAnim,
      builder: (context, _) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDanger
                  ? [_threatColor.withValues(alpha: 0.25), Colors.black.withValues(alpha: 0.6)]
                  : [const Color(0xFF00E676).withValues(alpha: 0.15), Colors.black.withValues(alpha: 0.6)],
            ),
          ),
          child: Stack(
            children: [
              // Línea de escaneo animada
              if (isDanger)
                Positioned(
                  top: _scanAnim.value * 60 - 2,
                  left: 0, right: 0,
                  child: Container(height: 2, decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.transparent, _threatColor.withValues(alpha: 0.8), Colors.transparent]))),
                ),
              Row(
                children: [
                  AnimatedBuilder(
                    animation: _pulseAnim,
                    builder: (context, _) => Container(
                      width: 52, height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _threatColor.withValues(alpha: 0.15 + _pulseAnim.value * 0.1),
                        border: Border.all(color: _threatColor.withValues(alpha: 0.6 + _pulseAnim.value * 0.4), width: 2),
                      ),
                      child: Icon(
                        isDanger ? Icons.gpp_bad_rounded : Icons.verified_user_rounded,
                        color: _threatColor, size: 28,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('ANÁLISIS VIRUSTOTAL', style: TextStyle(color: _threatColor.withValues(alpha: 0.7), fontSize: 10, letterSpacing: 2.5, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(label, style: TextStyle(color: _threatColor, fontSize: 20, fontWeight: FontWeight.w900, letterSpacing: 0.5)),
                        if (widget.vtData?['scanDate'] != null) ...[
                          const SizedBox(height: 3),
                          Text(widget.vtData!['scanDate'] as String, style: const TextStyle(color: Colors.white30, fontSize: 10)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildUrlBar(Map<String, dynamic> vt) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.link_rounded, color: Colors.white38, size: 14),
            const SizedBox(width: 6),
            const Text('URL ANALIZADA', style: TextStyle(color: Colors.white30, fontSize: 9, letterSpacing: 1.5)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFF1565C0).withValues(alpha: 0.4), borderRadius: BorderRadius.circular(4)),
              child: const Text('VirusTotal API v3', style: TextStyle(color: Color(0xFF64B5F6), fontSize: 8, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 5),
          Text(vt['url'] as String? ?? '', style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'), maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _buildScoreSection(Map<String, dynamic> vt) {
    final positives = (vt['positives'] as num?)?.toInt() ?? 0;
    final total = (vt['total'] as num?)?.toInt() ?? 1;
    final ratio = positives / total;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          // Gráfico circular de amenaza
          _ThreatGauge(ratio: ratio, positives: positives, total: total, color: _threatColor, revealAnim: _revealAnim),
          const SizedBox(width: 20),
          // Barras de desglose
          Expanded(child: _buildBreakdownBars(vt)),
        ],
      ),
    );
  }

  Widget _buildBreakdownBars(Map<String, dynamic> vt) {
    final total = (vt['total'] as num?)?.toDouble() ?? 1.0;
    final rows = [
      ('Maliciosos', (vt['malicious'] as num?)?.toInt() ?? 0, const Color(0xFFFF1744)),
      ('Sospechosos', (vt['suspicious'] as num?)?.toInt() ?? 0, const Color(0xFFFFD600)),
      ('Sin detectar', (vt['undetected'] as num?)?.toInt() ?? 0, Colors.white24),
      ('Limpios', (vt['harmless'] as num?)?.toInt() ?? 0, const Color(0xFF00E676)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows.map((r) {
        final (label, count, color) = r;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11))),
                Text('$count', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 4),
              AnimatedBuilder(
                animation: _revealAnim,
                builder: (context, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (count / total) * _revealAnim.value,
                    minHeight: 5,
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildEngineBreakdown(Map<String, dynamic> vt) {
    final positives = (vt['positives'] as num?)?.toInt() ?? 0;
    final total = (vt['total'] as num?)?.toInt() ?? 0;
    final harmless = (vt['harmless'] as num?)?.toInt() ?? 0;
    final suspicious = (vt['suspicious'] as num?)?.toInt() ?? 0;
    final malicious = (vt['malicious'] as num?)?.toInt() ?? 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _StatPill(label: 'MOTORES', value: '$total', icon: Icons.memory_rounded, color: Colors.white54),
              _StatPill(label: 'DETECTADO', value: '$positives', icon: Icons.bug_report_rounded, color: _threatColor),
              _StatPill(label: 'LIMPIO', value: '$harmless', icon: Icons.check_circle_outline_rounded, color: const Color(0xFF00E676)),
            ],
          ),
          if (suspicious > 0 || malicious > 0) ...[
            const Divider(color: Colors.white12, height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (malicious > 0) _MiniTag(label: '$malicious maliciosos', color: const Color(0xFFFF1744)),
              if (malicious > 0 && suspicious > 0) const SizedBox(width: 8),
              if (suspicious > 0) _MiniTag(label: '$suspicious sospechosos', color: const Color(0xFFFFD600)),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _buildUnavailable() {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Column(children: [
        Icon(Icons.cloud_off_rounded, color: Colors.white38, size: 48),
        SizedBox(height: 12),
        Text('Servicio no disponible', style: TextStyle(color: Colors.white54, fontSize: 14)),
        SizedBox(height: 4),
        Text('El agente realizará análisis manual', style: TextStyle(color: Colors.white30, fontSize: 12)),
      ]),
    );
  }

  Widget _buildCloseButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: GestureDetector(
        onTap: widget.onClose,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white12),
          ),
          child: const Text('Cerrar', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class _ThreatGauge extends StatelessWidget {
  final double ratio;
  final int positives;
  final int total;
  final Color color;
  final Animation<double> revealAnim;
  const _ThreatGauge({required this.ratio, required this.positives, required this.total, required this.color, required this.revealAnim});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88, height: 88,
      child: AnimatedBuilder(
        animation: revealAnim,
        builder: (context, _) => CustomPaint(
          painter: _GaugePainter(ratio: ratio * revealAnim.value, color: color),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('$positives', style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w900)),
              Text('/ $total', style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double ratio;
  final Color color;
  const _GaugePainter({required this.ratio, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2 - 6;
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
    final bg = Paint()..color = Colors.white.withValues(alpha: 0.07)..style = PaintingStyle.stroke..strokeWidth = 7..strokeCap = StrokeCap.round;
    final fg = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 7..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -pi / 2, 2 * pi, false, bg);
    if (ratio > 0) canvas.drawArc(rect, -pi / 2, 2 * pi * ratio, false, fg);
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.ratio != ratio || old.color != color;
}

class _MiniTag extends StatelessWidget {
  final String label;
  final Color color;
  const _MiniTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }
}

class _StatPill extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _StatPill({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800)),
      Text(label, style: const TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1.2)),
    ]);
  }
}

// ─── Speaking Wave ─────────────────────────────────────────────────────────────

class _SpeakingWave extends StatelessWidget {
  final Animation<double> anim; final ColorScheme colors;
  const _SpeakingWave({required this.anim, required this.colors});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(5, (i) {
          final h = 8.0 + 14.0 * ((anim.value + i * 0.2) % 1.0);
          return Container(width: 4, height: h, margin: const EdgeInsets.symmetric(horizontal: 1.5), decoration: BoxDecoration(color: colors.primary.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(2)));
        }),
      ),
    );
  }
}

// ─── Shared overlay base ────────────────────────────────────────────────────

/// Mixin con animaciones de entrada comunes para todos los overlays de seguridad.
mixin _SecurityOverlayAnimMixin<T extends StatefulWidget> on State<T>, TickerProviderStateMixin<T> {
  late final AnimationController revealCtrl;
  late final AnimationController pulseCtrl;
  late final Animation<double> revealAnim;
  late final Animation<double> pulseAnim;

  void initSecurityAnims() {
    revealCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();
    pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat(reverse: true);
    revealAnim = CurvedAnimation(parent: revealCtrl, curve: Curves.easeOutCubic);
    pulseAnim = CurvedAnimation(parent: pulseCtrl, curve: Curves.easeInOut);
  }

  void disposeSecurityAnims() {
    revealCtrl.dispose();
    pulseCtrl.dispose();
  }

  Color threatColor(String level) => switch (level) {
    'critical'   => const Color(0xFFFF1744),
    'dangerous'  => const Color(0xFFFF6D00),
    'suspicious' => const Color(0xFFFFD600),
    _            => const Color(0xFF00E676),
  };

  Widget overlayShell({required Color accent, required List<Widget> children}) {
    final size = MediaQuery.of(context).size;
    return FadeTransition(
      opacity: revealAnim,
      child: Center(
        child: Container(
          width: size.width * 0.92,
          margin: const EdgeInsets.only(bottom: 50),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: accent.withValues(alpha: 0.6), width: 1.5),
            boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.2), blurRadius: 40, spreadRadius: 4)],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }

  Widget overlayHeader({required IconData icon, required String badge, required String title, required Color accent, String? subtitle}) {
    return AnimatedBuilder(
      animation: pulseAnim,
      builder: (_, __) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [accent.withValues(alpha: 0.22), Colors.black.withValues(alpha: 0.5)],
          ),
        ),
        child: Row(children: [
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.15 + pulseAnim.value * 0.08),
              border: Border.all(color: accent.withValues(alpha: 0.5 + pulseAnim.value * 0.4), width: 2),
            ),
            child: Icon(icon, color: accent, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(badge, style: TextStyle(color: accent.withValues(alpha: 0.7), fontSize: 9, letterSpacing: 2.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(title, style: TextStyle(color: accent, fontSize: 18, fontWeight: FontWeight.w900)),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ])),
        ]),
      ),
    );
  }

  Widget overlayInfoRow(IconData icon, String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Icon(icon, color: Colors.white30, size: 14),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        const Spacer(),
        Flexible(child: Text(value, style: TextStyle(color: valueColor ?? Colors.white70, fontSize: 12, fontWeight: FontWeight.w600), textAlign: TextAlign.end, maxLines: 2, overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  Widget overlayCloseButton(VoidCallback onClose) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: GestureDetector(
        onTap: onClose,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white12)),
          child: const Text('Cerrar', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

// ─── IP Report Overlay ──────────────────────────────────────────────────────

class _IpReportOverlay extends StatefulWidget {
  final String title;
  final Map<String, dynamic>? ipData;
  final VoidCallback onClose;
  const _IpReportOverlay({required this.title, required this.ipData, required this.onClose});
  @override
  State<_IpReportOverlay> createState() => _IpReportOverlayState();
}

class _IpReportOverlayState extends State<_IpReportOverlay>
    with TickerProviderStateMixin, _SecurityOverlayAnimMixin {
  @override
  void initState() { super.initState(); initSecurityAnims(); }
  @override
  void dispose() { disposeSecurityAnims(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final d = widget.ipData;
    final level = d?['threatLevel'] as String? ?? 'clean';
    final accent = threatColor(level);
    final isDanger = d?['isDanger'] as bool? ?? false;

    return overlayShell(accent: accent, children: [
      overlayHeader(
        icon: isDanger ? Icons.language_rounded : Icons.public_rounded,
        badge: 'ANÁLISIS DE IP — VIRUSTOTAL',
        title: widget.title,
        accent: accent,
        subtitle: d?['ip'] as String?,
      ),
      if (d != null) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(children: [
            overlayInfoRow(Icons.flag_rounded, 'País', d['country'] as String? ?? '—'),
            overlayInfoRow(Icons.business_rounded, 'Proveedor', d['asOwner'] as String? ?? '—'),
            overlayInfoRow(Icons.router_rounded, 'Red', d['network'] as String? ?? '—'),
            overlayInfoRow(Icons.thumb_down_rounded, 'Reputación VT',
              '${d['reputation'] ?? 0}',
              valueColor: (d['reputation'] as num? ?? 0) < 0 ? const Color(0xFFFF6D00) : const Color(0xFF00E676),
            ),
            const Divider(color: Colors.white12, height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _StatPill(label: 'MOTORES', value: '${d['total'] ?? 0}', icon: Icons.memory_rounded, color: Colors.white54),
              _StatPill(label: 'DETECTADO', value: '${d['positives'] ?? 0}', icon: Icons.bug_report_rounded, color: accent),
              _StatPill(label: 'LIMPIO', value: '${d['harmless'] ?? 0}', icon: Icons.check_circle_outline_rounded, color: const Color(0xFF00E676)),
            ]),
          ]),
        ),
      ] else ...[
        const Padding(padding: EdgeInsets.all(20), child: Text('No hay datos disponibles', style: TextStyle(color: Colors.white38))),
      ],
      overlayCloseButton(widget.onClose),
    ]);
  }
}

// ─── Domain Report Overlay ──────────────────────────────────────────────────

class _DomainReportOverlay extends StatefulWidget {
  final String title;
  final Map<String, dynamic>? domainData;
  final VoidCallback onClose;
  const _DomainReportOverlay({required this.title, required this.domainData, required this.onClose});
  @override
  State<_DomainReportOverlay> createState() => _DomainReportOverlayState();
}

class _DomainReportOverlayState extends State<_DomainReportOverlay>
    with TickerProviderStateMixin, _SecurityOverlayAnimMixin {
  @override
  void initState() { super.initState(); initSecurityAnims(); }
  @override
  void dispose() { disposeSecurityAnims(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final d = widget.domainData;
    final level = d?['threatLevel'] as String? ?? 'clean';
    final accent = threatColor(level);
    final isDanger = d?['isDanger'] as bool? ?? false;

    return overlayShell(accent: accent, children: [
      overlayHeader(
        icon: isDanger ? Icons.domain_disabled_rounded : Icons.domain_rounded,
        badge: 'ANÁLISIS DE DOMINIO — VIRUSTOTAL',
        title: widget.title,
        accent: accent,
        subtitle: d?['domain'] as String?,
      ),
      if (d != null) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(children: [
            overlayInfoRow(Icons.business_center_rounded, 'Registrador', d['registrar'] as String? ?? '—'),
            overlayInfoRow(Icons.calendar_today_rounded, 'Fecha de registro', d['creationDate'] as String? ?? '—'),
            overlayInfoRow(Icons.category_rounded, 'Categorías', d['categories'] as String? ?? '—'),
            overlayInfoRow(Icons.thumb_down_rounded, 'Reputación VT',
              '${d['reputation'] ?? 0}',
              valueColor: (d['reputation'] as num? ?? 0) < 0 ? const Color(0xFFFF6D00) : const Color(0xFF00E676),
            ),
            const Divider(color: Colors.white12, height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _StatPill(label: 'MOTORES', value: '${d['total'] ?? 0}', icon: Icons.memory_rounded, color: Colors.white54),
              _StatPill(label: 'DETECTADO', value: '${d['positives'] ?? 0}', icon: Icons.bug_report_rounded, color: accent),
              _StatPill(label: 'LIMPIO', value: '${d['harmless'] ?? 0}', icon: Icons.check_circle_outline_rounded, color: const Color(0xFF00E676)),
            ]),
          ]),
        ),
      ] else ...[
        const Padding(padding: EdgeInsets.all(20), child: Text('No hay datos disponibles', style: TextStyle(color: Colors.white38))),
      ],
      overlayCloseButton(widget.onClose),
    ]);
  }
}

// ─── Password Check Overlay ─────────────────────────────────────────────────

class _PasswordCheckOverlay extends StatefulWidget {
  final String title;
  final Map<String, dynamic>? passwordData;
  final VoidCallback onClose;
  const _PasswordCheckOverlay({required this.title, required this.passwordData, required this.onClose});
  @override
  State<_PasswordCheckOverlay> createState() => _PasswordCheckOverlayState();
}

class _PasswordCheckOverlayState extends State<_PasswordCheckOverlay>
    with TickerProviderStateMixin, _SecurityOverlayAnimMixin {
  late final AnimationController _counterCtrl;

  String _formatNumber(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write('.');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  @override
  void initState() {
    super.initState();
    initSecurityAnims();
    _counterCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..forward();
  }

  @override
  void dispose() {
    _counterCtrl.dispose();
    disposeSecurityAnims();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.passwordData;
    final level = d?['threatLevel'] as String? ?? 'clean';
    final accent = threatColor(level);
    final pwned = d?['pwned'] as bool? ?? false;
    final count = (d?['count'] as num?)?.toInt() ?? 0;

    return overlayShell(accent: accent, children: [
      overlayHeader(
        icon: pwned ? Icons.lock_open_rounded : Icons.lock_rounded,
        badge: 'VERIFICACIÓN DE BRECHAS — HIBP',
        title: widget.title,
        accent: accent,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(children: [
          // Contador animado de exposiciones
          if (pwned) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: accent.withValues(alpha: 0.3)),
              ),
              child: Column(children: [
                Text('APARECE EN', style: TextStyle(color: accent.withValues(alpha: 0.7), fontSize: 9, letterSpacing: 2.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                AnimatedBuilder(
                  animation: _counterCtrl,
                  builder: (_, __) {
                    final displayed = (count * _counterCtrl.value).round();
                    return Text(
                      _formatNumber(displayed),
                      style: TextStyle(color: accent, fontSize: 36, fontWeight: FontWeight.w900, letterSpacing: -1),
                    );
                  },
                ),
                Text('filtraciones conocidas', style: TextStyle(color: accent.withValues(alpha: 0.6), fontSize: 12)),
              ]),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFD600), size: 16),
                const SizedBox(width: 8),
                const Expanded(child: Text('Cambia esta contraseña inmediatamente y no la uses en ningún otro sitio.', style: TextStyle(color: Colors.white60, fontSize: 11, height: 1.4))),
              ]),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 24),
              decoration: BoxDecoration(
                color: const Color(0xFF00E676).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF00E676).withValues(alpha: 0.3)),
              ),
              child: Column(children: [
                const Icon(Icons.verified_user_rounded, color: Color(0xFF00E676), size: 48),
                const SizedBox(height: 8),
                const Text('No encontrada en filtraciones', style: TextStyle(color: Color(0xFF00E676), fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text('Verificado con k-Anonymity (la contraseña nunca salió del dispositivo)', style: TextStyle(color: Colors.white30, fontSize: 10), textAlign: TextAlign.center),
              ]),
            ),
          ],
        ]),
      ),
      overlayCloseButton(widget.onClose),
    ]);
  }
}

// ─── Password Generated Overlay ─────────────────────────────────────────────

class _PasswordGeneratedOverlay extends StatefulWidget {
  final Map<String, dynamic>? passwordData;
  final VoidCallback onClose;
  const _PasswordGeneratedOverlay({required this.passwordData, required this.onClose});
  @override
  State<_PasswordGeneratedOverlay> createState() => _PasswordGeneratedOverlayState();
}

class _PasswordGeneratedOverlayState extends State<_PasswordGeneratedOverlay>
    with TickerProviderStateMixin, _SecurityOverlayAnimMixin {
  bool _visible = false;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    initSecurityAnims();
  }

  @override
  void dispose() { disposeSecurityAnims(); super.dispose(); }

  void _copyToClipboard() {
    final pwd = widget.passwordData?['password'] as String? ?? '';
    Clipboard.setData(ClipboardData(text: pwd));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () { if (mounted) setState(() => _copied = false); });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.passwordData;
    final password = d?['password'] as String? ?? '';
    final length = (d?['length'] as num?)?.toInt() ?? 20;
    final entropy = (d?['entropy'] as num?)?.toInt() ?? 0;
    const accent = Color(0xFF00E676);

    return overlayShell(accent: accent, children: [
      overlayHeader(
        icon: Icons.key_rounded,
        badge: 'GENERADOR DE CONTRASEÑA SEGURA',
        title: 'Contraseña Lista',
        accent: accent,
        subtitle: '$length caracteres · $entropy bits de entropía',
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(children: [
          // Campo de contraseña con toggle de visibilidad
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent.withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              Expanded(
                child: _visible
                    ? SelectableText(password, style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace', letterSpacing: 1.2))
                    : Text('•' * password.length, style: const TextStyle(color: Colors.white54, fontSize: 10, letterSpacing: 2)),
              ),
              IconButton(
                icon: Icon(_visible ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: Colors.white38, size: 20),
                onPressed: () => setState(() => _visible = !_visible),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          // Botón copiar
          GestureDetector(
            onTap: _copyToClipboard,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                color: _copied ? accent.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _copied ? accent.withValues(alpha: 0.6) : Colors.white12),
              ),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, color: _copied ? accent : Colors.white54, size: 18),
                const SizedBox(width: 8),
                Text(_copied ? 'Copiada al portapapeles' : 'Copiar contraseña',
                  style: TextStyle(color: _copied ? accent : Colors.white60, fontWeight: FontWeight.w600, fontSize: 13)),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          // Barra de entropía
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Fortaleza', style: TextStyle(color: Colors.white38, fontSize: 11)),
              const Spacer(),
              Text('$entropy bits', style: const TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 6),
            AnimatedBuilder(
              animation: revealAnim,
              builder: (_, __) => ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: (entropy / 140).clamp(0.0, 1.0) * revealAnim.value,
                  minHeight: 6,
                  backgroundColor: Colors.white.withValues(alpha: 0.07),
                  valueColor: const AlwaysStoppedAnimation(accent),
                ),
              ),
            ),
          ]),
        ]),
      ),
      overlayCloseButton(widget.onClose),
    ]);
  }
}

// ─── Scan Progress Overlay (QR / File) ──────────────────────────────────────

class _ScanProgressOverlay extends StatefulWidget {
  final String title;
  final List<dynamic> items;
  final VoidCallback onClose;
  const _ScanProgressOverlay({required this.title, required this.items, required this.onClose});
  @override
  State<_ScanProgressOverlay> createState() => _ScanProgressOverlayState();
}

class _ScanProgressOverlayState extends State<_ScanProgressOverlay>
    with TickerProviderStateMixin, _SecurityOverlayAnimMixin {
  late final AnimationController _scanLineCtrl;

  @override
  void initState() {
    super.initState();
    initSecurityAnims();
    _scanLineCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  }

  @override
  void dispose() { _scanLineCtrl.dispose(); disposeSecurityAnims(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF40C4FF);
    final item = widget.items.isNotEmpty ? widget.items.first as Map<String, dynamic> : null;
    final imgUrl = item?['imageUrl'] as String?;

    return overlayShell(accent: accent, children: [
      overlayHeader(
        icon: Icons.qr_code_scanner_rounded,
        badge: 'ESCÁNER DE SEGURIDAD',
        title: widget.title,
        accent: accent,
      ),
      if (imgUrl != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Stack(
            alignment: Alignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: imgUrl.startsWith('data:')
                    ? Image.memory(base64Decode(imgUrl.split(',').last), width: double.infinity, height: 160, fit: BoxFit.cover)
                    : Image.network(imgUrl, width: double.infinity, height: 160, fit: BoxFit.cover),
              ),
              // Línea de escaneo animada sobre la imagen
              AnimatedBuilder(
                animation: _scanLineCtrl,
                builder: (_, __) => Positioned(
                  top: _scanLineCtrl.value * 140,
                  left: 0, right: 0,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Colors.transparent, accent.withValues(alpha: 0.9), Colors.transparent]),
                    ),
                  ),
                ),
              ),
              // Esquinas del escáner
              ..._buildScanCorners(accent),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(accent))),
          const SizedBox(width: 12),
          Text(item?['description'] as String? ?? 'Analizando...', style: const TextStyle(color: Colors.white60, fontSize: 13)),
        ]),
      ),
      overlayCloseButton(widget.onClose),
    ]);
  }

  List<Widget> _buildScanCorners(Color accent) {
    const size = 20.0;
    const thick = 3.0;
    Widget corner(AlignmentGeometry align, BorderRadius br) => Positioned.fill(
      child: Align(alignment: align, child: Container(
        width: size, height: size,
        decoration: BoxDecoration(border: Border(
          top: align == Alignment.topLeft || align == Alignment.topRight ? BorderSide(color: accent, width: thick) : BorderSide.none,
          bottom: align == Alignment.bottomLeft || align == Alignment.bottomRight ? BorderSide(color: accent, width: thick) : BorderSide.none,
          left: align == Alignment.topLeft || align == Alignment.bottomLeft ? BorderSide(color: accent, width: thick) : BorderSide.none,
          right: align == Alignment.topRight || align == Alignment.bottomRight ? BorderSide(color: accent, width: thick) : BorderSide.none,
        ), borderRadius: br),
      )),
    );
    return [
      corner(Alignment.topLeft, const BorderRadius.only(topLeft: Radius.circular(6))),
      corner(Alignment.topRight, const BorderRadius.only(topRight: Radius.circular(6))),
      corner(Alignment.bottomLeft, const BorderRadius.only(bottomLeft: Radius.circular(6))),
      corner(Alignment.bottomRight, const BorderRadius.only(bottomRight: Radius.circular(6))),
    ];
  }
}
