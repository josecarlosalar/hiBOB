import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
            setState(() => _showCameraPreview = true);
            _hideCameraTimer?.cancel();
            _hideCameraTimer = Timer(const Duration(seconds: 10), () { if (mounted) setState(() => _showCameraPreview = false); });
          }
          final frame = await _captureFrame(source: source);
          if (frame != null) _liveSession.sendFrame(frameBase64: frame);
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
    if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized) return null;
    try {
      final file = await _cameraCtrl!.takePicture();
      final bytes = await File(file.path).readAsBytes();
      final base64 = base64Encode(bytes);
      
      // Si el backend pidió un frame, se lo enviamos con un prompt contextual
      if (source == 'camera') {
        _liveSession.sendFrame(
          frameBase64: base64,
          prompt: 'Esta es la imagen actual de mi cámara. Descríbela de forma natural.',
        );
      }
      return base64;
    } catch (e) { return null; }
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
          if (_structuredContent != null) _buildStructuredPanel(size, colors),
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
    return IgnorePointer(ignoring: !_showCameraPreview, child: AnimatedOpacity(opacity: _showCameraPreview ? 1.0 : 0.0, duration: const Duration(milliseconds: 600), child: Center(child: AnimatedScale(scale: _showCameraPreview ? 1.0 : 0.85, duration: const Duration(milliseconds: 600), child: Container(
      width: size.width * 0.92, height: size.height * 0.62,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(32), border: Border.all(color: Colors.white24, width: 2), boxShadow: [const BoxShadow(color: Colors.black54, blurRadius: 30)]),
      clipBehavior: Clip.antiAlias,
      child: (_cameraCtrl != null && _cameraCtrl!.value.isInitialized) ? CameraPreview(_cameraCtrl!) : Container(color: Colors.grey[900], child: const Icon(Icons.camera_alt, color: Colors.white24, size: 64)),
    )))));
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

  Widget _buildStructuredPanel(Size size, ColorScheme colors) {
    final isDetail = _selectedItem != null;
    final title = isDetail ? _selectedItem!['title'] : _structuredContent!['title'];
    final items = _structuredContent!['items'] as List<dynamic>? ?? [];
    return Center(child: Container(width: size.width * 0.88, height: size.height * 0.55, margin: const EdgeInsets.only(bottom: 60), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(32), border: Border.all(color: Colors.white10), boxShadow: [const BoxShadow(color: Colors.black38, blurRadius: 40)]), clipBehavior: Clip.antiAlias, child: Column(children: [
      _buildPanelHeader(title, isDetail),
      Expanded(child: isDetail ? _buildDetailView(_selectedItem!, colors) : _buildListView(items, colors)),
    ])));
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
      final item = items[index];
      return InkWell(onTap: () => setState(() => _selectedItem = item), borderRadius: BorderRadius.circular(16), child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(16)), child: Row(children: [
        if (item['imageUrl'] != null) ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(item['imageUrl'], width: 50, height: 50, fit: BoxFit.cover, errorBuilder: (_,__,___) => const Icon(Icons.image, color: Colors.white24))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(item['title'] ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), Text(item['description'] ?? '', style: const TextStyle(color: Colors.white60, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis)]))
      ])));
    });
  }

  Widget _buildDetailView(Map<String, dynamic> item, ColorScheme colors) {
    return SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (item['imageUrl'] != null) ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.network(item['imageUrl'], width: double.infinity, height: 150, fit: BoxFit.cover)),
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
