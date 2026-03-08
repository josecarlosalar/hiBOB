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
import 'package:flutter_background_service/flutter_background_service.dart';

import '../../../core/providers/firebase_providers.dart';
import '../../../core/services/audio_service.dart';
import '../../../core/services/live_session_service.dart';
import '../../../core/services/pcm_audio_service.dart';

enum AssistantState { inactive, listening, speaking }

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const String _settingsFileName = 'conversation_settings.json';
  final GlobalKey _screenCaptureKey = GlobalKey();
  
  static const double _defaultVadThresholdDb = -68.0;
  static const double _defaultBargeInThresholdDb = -10.0;
  static const int _defaultSilenceMs = 650;
  static const int _defaultMinRecordMs = 450;
  static const int _defaultMinBargeInMs = 900;
  static const int _defaultAgentSpeechGraceMs = 900;

  CameraController? _cameraCtrl;
  List<CameraDescription> _availableCameras = const [];
  CameraLensDirection _selectedLensDirection = CameraLensDirection.front;

  final LiveSessionService _liveSession = LiveSessionService();
  final AudioService _audio = AudioService();
  final PcmAudioService _pcmAudio = PcmAudioService();

  AssistantState _state = AssistantState.inactive;
  double _vadThresholdDb = _defaultVadThresholdDb;
  double _bargeInThresholdDb = _defaultBargeInThresholdDb;
  int _silenceMs = _defaultSilenceMs;
  int _minRecordMs = _defaultMinRecordMs;
  int _minBargeInMs = _defaultMinBargeInMs;
  int _agentSpeechGraceMs = _defaultAgentSpeechGraceMs;
  String _conversationProfile = 'Equilibrado';

  StreamSubscription<String>? _audioStreamSub;
  StreamSubscription<Amplitude>? _amplitudeSub;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _locationTimer;
  Timer? _agentSpeechIdleTimer;
  DateTime? _bargeInStartedAt;
  DateTime? _agentSpeechStartedAt;
  bool _agentAudioActive = false;
  double _lastAmplitudeDb = -160.0;
  bool _showCameraPreview = false;
  Timer? _hideCameraTimer;
  Map<String, dynamic>? _structuredContent;
  Map<String, dynamic>? _selectedItem;

  late final AnimationController _pulseCtrl;
  late final AnimationController _waveCtrl;
  late final Animation<double> _pulseAnim;
  late final Animation<double> _waveAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAnimations();
    _initCamera();
    unawaited(_loadConversationSettings());
    _liveSession.onDisplayContent.listen((data) {
      if (mounted) setState(() => _structuredContent = data);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[Lifecycle] Cambio a: $state');
  }

  void _initAnimations() {
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 0.88, end: 1.12).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _waveAnim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _waveCtrl, curve: Curves.easeInOut),
    );
  }

  Future<void> _initCamera() async {
    _availableCameras = await availableCameras();
    if (_availableCameras.isEmpty) return;

    final selectedCamera = _findCameraForLens(_selectedLensDirection) ??
        _availableCameras.first;
    _selectedLensDirection = selectedCamera.lensDirection;

    _cameraCtrl = CameraController(
      selectedCamera,
      ResolutionPreset.low,
      enableAudio: false,
    );
    await _cameraCtrl!.initialize();
    if (mounted) setState(() {});
  }

  CameraDescription? _findCameraForLens(CameraLensDirection lensDirection) {
    for (final camera in _availableCameras) {
      if (camera.lensDirection == lensDirection) return camera;
    }
    return null;
  }

  bool get _hasFrontCamera => _findCameraForLens(CameraLensDirection.front) != null;
  bool get _hasBackCamera => _findCameraForLens(CameraLensDirection.back) != null;
  bool get _bargeInEnabled => _conversationProfile == 'Interrupcion facil';

  Future<void> _switchCamera(CameraLensDirection lensDirection) async {
    if (_selectedLensDirection == lensDirection) return;
    final selectedCamera = _findCameraForLens(lensDirection);
    if (selectedCamera == null) return;

    final previousController = _cameraCtrl;
    final nextController = CameraController(selectedCamera, ResolutionPreset.low, enableAudio: false);

    try {
      await nextController.initialize();
      _cameraCtrl = nextController;
      _selectedLensDirection = lensDirection;
      if (mounted) setState(() {});
      await previousController?.dispose();
    } catch (_) {
      await nextController.dispose();
    }
  }

  Future<void> _startSession() async {
    final hasPerm = await _audio.hasPermission;
    if (!hasPerm) { _showMessage('Necesito permiso de microfono'); return; }

    final firebase = ref.read(firebaseServiceProvider);
    final token = await firebase.getIdToken();
    if (token == null) { _showMessage('No se pudo autenticar'); return; }

    await _pcmAudio.init();

    _subs.addAll([
      _liveSession.onStateChange.listen((s) {
        if (!mounted) return;
        if (s == LiveSessionState.connected) _startStreaming();
        else if (s == LiveSessionState.error) { _stopSession(); _showMessage('Error de conexion'); }
        else if (s == LiveSessionState.disconnected && _state != AssistantState.inactive) _stopSession();
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
        final payload = data as Map<String, dynamic>?;
        final source = payload?['source'] as String? ?? 'camera';

        if (source == 'camera') {
          setState(() => _showCameraPreview = true);
          _hideCameraTimer?.cancel();
          _hideCameraTimer = Timer(const Duration(seconds: 10), () {
            if (mounted) setState(() => _showCameraPreview = false);
          });
        } else {
          if (mounted) setState(() => _showCameraPreview = false);
        }

        final frame = await _captureFrame(source: source);
        if (frame != null) _liveSession.sendFrame(frameBase64: frame);
      }),
      _liveSession.onCommand.listen((cmd) { if (mounted) _handleHardwareCommand(cmd); }),
      _liveSession.onError.listen((msg) { _showMessage('Asistente: $msg'); }),
    ]);

    await _liveSession.connect(token);
    unawaited(_startLocationUpdates());
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

  void _handleAmplitudeSample(Amplitude amp) {
    _lastAmplitudeDb = amp.current;
    if (!_agentAudioActive) return;
    final now = DateTime.now();
    final graceElapsed = _agentSpeechStartedAt != null && now.difference(_agentSpeechStartedAt!).inMilliseconds >= _agentSpeechGraceMs;
    if (!graceElapsed) return;

    if (amp.current >= _bargeInThresholdDb) {
      _bargeInStartedAt ??= now;
      if (now.difference(_bargeInStartedAt!).inMilliseconds >= 900 && _bargeInEnabled) _stopSpeaking();
    } else {
      _bargeInStartedAt = null;
    }
  }

  bool _shouldForwardAudioChunk() {
    if (!_agentAudioActive) return true;
    return _conversationProfile == 'Interrupcion facil';
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
      final direction = cmd['direction'] as String?;
      await _switchCamera(direction == 'front' ? CameraLensDirection.front : CameraLensDirection.back);
    } else if (action == 'start_copilot_mode') {
      FlutterBackgroundService().invoke('setAsForeground');
      _showMessage('Modo Copiloto activado. Puedes minimizar.');
    } else if (action == 'vibrate') {
      if (await Vibration.hasVibrator()) Vibration.vibrate(duration: 100);
    }
  }

  Future<String?> _captureFrame({String source = 'camera'}) async {
    if (source == 'screen') {
      try {
        final boundary = _screenCaptureKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
        if (boundary == null) return null;
        final image = await boundary.toImage(pixelRatio: 1.0);
        final byteData = await image.toByteData(format: ImageByteFormat.png);
        return base64Encode(byteData!.buffer.asUint8List());
      } catch (e) { return null; }
    }
    if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized) return null;
    try {
      final file = await _cameraCtrl!.takePicture();
      final bytes = await File(file.path).readAsBytes();
      return base64Encode(bytes);
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
  }

  void _setStateIfMounted(AssistantState newState) {
    if (!mounted || _state == newState) return;
    if (_conversationProfile == 'Interrupcion facil' || newState == AssistantState.inactive) {
      if (newState == AssistantState.listening) Vibration.vibrate(duration: 50);
    }
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

  void _openFineTuningPanel() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(builder: (context, modalSetState) {
          void updateSettings(VoidCallback update) { modalSetState(update); setState(() {}); unawaited(_persistConversationSettings()); }
          return SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 28), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Ajuste fino', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              _CalibrationChip(label: 'Equilibrado', isSelected: _conversationProfile == 'Equilibrado', onTap: () => updateSettings(() => _applyConversationProfile('Equilibrado'))),
              _CalibrationChip(label: 'Evitar cortes', isSelected: _conversationProfile == 'Evitar cortes', onTap: () => updateSettings(() => _applyConversationProfile('Evitar cortes'))),
              _CalibrationChip(label: 'Interrupcion facil', isSelected: _conversationProfile == 'Interrupcion facil', onTap: () => updateSettings(() => _applyConversationProfile('Interrupcion facil'))),
            ]),
            _SettingSlider(label: 'Sensibilidad', valueLabel: '${_vadThresholdDb.toInt()} dB', value: _vadThresholdDb, min: -80, max: -35, divisions: 45, onChanged: (v) => updateSettings(() => _vadThresholdDb = v)),
          ])));
        });
      },
    );
  }

  void _applyConversationProfile(String profile) {
    _conversationProfile = profile;
    if (profile == 'Evitar cortes') { _vadThresholdDb = -66; _silenceMs = 800; }
    else if (profile == 'Interrupcion facil') { _vadThresholdDb = -68; _bargeInThresholdDb = -16; }
    else { _vadThresholdDb = _defaultVadThresholdDb; _silenceMs = _defaultSilenceMs; }
  }

  Future<File> _settingsFile() async { final dir = await getApplicationSupportDirectory(); return File('${dir.path}/$_settingsFileName'); }
  Future<void> _loadConversationSettings() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      setState(() { _conversationProfile = json['conversationProfile'] ?? 'Equilibrado'; _vadThresholdDb = json['vadThresholdDb'] ?? _defaultVadThresholdDb; });
    } catch (_) {}
  }
  Future<void> _persistConversationSettings() async {
    try { await (await _settingsFile()).writeAsString(jsonEncode({'conversationProfile': _conversationProfile, 'vadThresholdDb': _vadThresholdDb})); } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    return RepaintBoundary(key: _screenCaptureKey, child: Scaffold(backgroundColor: Colors.black, body: Stack(children: [
      _buildGeminiAura(colors),
      _buildTopOverlay(),
      _buildCameraPreview(size),
      if (_structuredContent != null) _buildStructuredPanel(size, colors),
      _buildBottomControlBar(colors),
    ])));
  }

  Widget _buildGeminiAura(ColorScheme colors) {
    Color auraColor = _state == AssistantState.listening ? colors.secondary.withValues(alpha: 0.3) : (_state == AssistantState.speaking ? Colors.cyanAccent.withValues(alpha: 0.38) : colors.primary.withValues(alpha: 0.14));
    return AnimatedContainer(duration: const Duration(milliseconds: 800), decoration: BoxDecoration(gradient: RadialGradient(colors: [auraColor, Colors.black87, Colors.black], center: Alignment.center, radius: 1.2)));
  }

  Widget _buildCameraPreview(Size size) {
    return IgnorePointer(ignoring: !_showCameraPreview, child: AnimatedOpacity(opacity: _showCameraPreview ? 1.0 : 0.0, duration: const Duration(milliseconds: 600), child: Center(child: AnimatedScale(scale: _showCameraPreview ? 1.0 : 0.85, duration: const Duration(milliseconds: 600), child: Container(
      width: size.width * 0.92, height: size.height * 0.62,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(32), border: Border.all(color: Colors.white24, width: 2), boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 30)]),
      clipBehavior: Clip.antiAlias,
      child: (_cameraCtrl != null && _cameraCtrl!.value.isInitialized) ? CameraPreview(_cameraCtrl!) : Container(color: Colors.grey[900], child: const Icon(Icons.camera_alt, color: Colors.white24, size: 64)),
    )))));
  }

  Widget _buildTopOverlay() {
    return Positioned(top: 40, left: 20, right: 20, child: Row(children: [
      _StatusBadge(state: _state), const Spacer(),
      _CircleButton(icon: Icons.tune_rounded, onTap: _openFineTuningPanel), const SizedBox(width: 10),
      _CircleButton(icon: _cameraCtrl?.value.flashMode == FlashMode.torch ? Icons.flashlight_on : Icons.flashlight_off, onTap: _toggleFlashLocally), const SizedBox(width: 10),
      _CircleButton(icon: Icons.logout_rounded, onTap: _signOut),
    ]));
  }

  Widget _buildBottomControlBar(ColorScheme colors) {
    return Positioned(left: 20, right: 20, bottom: 34, child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12), decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(40), border: Border.all(color: Colors.white10), boxShadow: [BoxShadow(color: colors.primary.withValues(alpha: 0.15), blurRadius: 24)]), child: Row(children: [
      _buildAiActionButton(colors), const Spacer(), _buildStateSpecificContent(colors), const SizedBox(width: 12),
    ])));
  }

  Widget _buildAiActionButton(ColorScheme colors) {
    final isActive = _state != AssistantState.inactive;
    return GestureDetector(onTap: isActive ? _stopSession : _startSession, child: Container(width: 56, height: 56, decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [colors.primary, colors.secondary])), child: Icon(isActive ? Icons.stop_rounded : Icons.auto_awesome, color: Colors.white, size: 28)));
  }

  Widget _buildStateSpecificContent(ColorScheme colors) {
    if (_state == AssistantState.listening) return ScaleTransition(scale: _pulseAnim, child: const Icon(Icons.hearing_rounded, color: Colors.white70, size: 30));
    if (_state == AssistantState.speaking) return _SpeakingWave(anim: _waveAnim, colors: colors);
    return const Icon(Icons.keyboard_voice_rounded, color: Colors.white54, size: 24);
  }

  Widget _buildStructuredPanel(Size size, ColorScheme colors) {
    final isDetail = _selectedItem != null;
    final title = isDetail ? _selectedItem!['title'] : _structuredContent!['title'];
    final items = _structuredContent!['items'] as List<dynamic>? ?? [];
    return Center(child: Container(width: size.width * 0.88, height: size.height * 0.55, margin: const EdgeInsets.only(bottom: 60), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(32), border: Border.all(color: Colors.white10), boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 40)]), clipBehavior: Clip.antiAlias, child: Column(children: [
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
      if (item['url'] != null) ...[const SizedBox(height: 24), SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: () => _launchUrl(item['url']), icon: const Icon(Icons.open_in_new), label: const Text('Ver más')))]
    ]));
  }

  Future<void> _launchUrl(String url) async { _showMessage('Abriendo enlace...'); }
  Future<void> _signOut() async { _stopSession(); await ref.read(firebaseServiceProvider).signOut(); }
}

class _SpeakingWave extends StatelessWidget {
  final Animation<double> anim; final ColorScheme colors;
  const _SpeakingWave({required this.anim, required this.colors});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(animation: anim, builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: List.generate(5, (i) {
      final height = 10.0 + 20.0 * ((sin(anim.value * pi + (i / 4.0 * pi)) + 1) / 2);
      return Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Container(width: 4, height: height, decoration: BoxDecoration(color: colors.secondary, borderRadius: BorderRadius.circular(2))));
    })));
  }
}

class _StatusBadge extends StatelessWidget {
  final AssistantState state;
  const _StatusBadge({required this.state});
  @override
  Widget build(BuildContext context) {
    return Container(width: 48, height: 48, decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle, border: Border.all(color: Colors.white10)), child: Center(child: Icon(state == AssistantState.listening ? Icons.hearing : (state == AssistantState.speaking ? Icons.graphic_eq : Icons.power_settings_new), color: Colors.white, size: 20)));
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

class _CircleButton extends StatelessWidget {
  final IconData icon; final VoidCallback onTap;
  const _CircleButton({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap, child: Container(width: 44, height: 44, decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle, border: Border.all(color: Colors.white24)), child: Icon(icon, color: Colors.white, size: 22)));
  }
}

class _SettingSlider extends StatelessWidget {
  final String label, valueLabel; final double value, min, max; final int divisions; final ValueChanged<double> onChanged;
  const _SettingSlider({required this.label, required this.valueLabel, required this.value, required this.min, required this.max, required this.divisions, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14))), Text(valueLabel, style: const TextStyle(color: Colors.white70, fontSize: 12))]),
      Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
    ]);
  }
}
