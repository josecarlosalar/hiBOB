import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' show Amplitude;
import 'package:geolocator/geolocator.dart';
import 'package:torch_light/torch_light.dart';
import 'package:vibration/vibration.dart';

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
    with TickerProviderStateMixin {
  static const String _settingsFileName = 'conversation_settings.json';
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

  bool get _hasFrontCamera =>
      _findCameraForLens(CameraLensDirection.front) != null;

  bool get _hasBackCamera =>
      _findCameraForLens(CameraLensDirection.back) != null;

  bool get _bargeInEnabled =>
      _conversationProfile == 'Interrupcion facil';

  Future<void> _switchCamera(CameraLensDirection lensDirection) async {
    if (_selectedLensDirection == lensDirection) return;

    final selectedCamera = _findCameraForLens(lensDirection);
    if (selectedCamera == null) {
      _showMessage(
        lensDirection == CameraLensDirection.front
            ? 'No hay camara frontal disponible'
            : 'No hay camara trasera disponible',
      );
      return;
    }

    final previousController = _cameraCtrl;
    final nextController = CameraController(
      selectedCamera,
      ResolutionPreset.low,
      enableAudio: false,
    );

    try {
      await nextController.initialize();
      _cameraCtrl = nextController;
      _selectedLensDirection = lensDirection;
      if (mounted) setState(() {});
      await previousController?.dispose();
    } catch (e) {
      await nextController.dispose();
      debugPrint('[Camera] switch error: $e');
      _showMessage('No se pudo cambiar de camara');
    }
  }

  Future<void> _startSession() async {
    final hasPerm = await _audio.hasPermission;
    if (!hasPerm) {
      _showMessage('Necesito permiso de microfono');
      return;
    }

    final firebase = ref.read(firebaseServiceProvider);
    final token = await firebase.getIdToken();
    if (token == null) {
      _showMessage('No se pudo autenticar la sesion');
      return;
    }

    await _pcmAudio.init();

    _subs.addAll([
      _liveSession.onStateChange.listen((s) {
        if (!mounted) return;
        switch (s) {
          case LiveSessionState.connected:
            _startStreaming();
            break;
          case LiveSessionState.error:
            _stopSession();
            _showMessage('Error de conexion con el asistente');
            break;
          case LiveSessionState.disconnected:
            if (_state != AssistantState.inactive) {
              _stopSession();
            }
            break;
          case LiveSessionState.connecting:
            _setStateIfMounted(AssistantState.listening);
            break;
        }
      }),
      _liveSession.onAudioChunk.listen((audioChunk) {
        if (!mounted) return;
        _markAgentSpeechActive();
        _setStateIfMounted(AssistantState.speaking);
        final base64Audio = audioChunk['data'] ?? '';
        final mimeType = audioChunk['mimeType'];
        _pcmAudio.feedBase64(base64Audio, mimeType: mimeType);
      }),
      _liveSession.onInterruption.listen((_) {
        if (!mounted) return;
        _stopSpeaking();
      }),
      _liveSession.onDone.listen((_) {
        if (!mounted) return;
        _handleAgentSpeechEnded();
      }),
      _liveSession.onFrameRequest.listen((_) async {
        if (!mounted) return;
        final frame = await _captureFrame();
        if (frame != null) {
          _liveSession.sendFrame(frameBase64: frame);
        }
      }),
      _liveSession.onCommand.listen((cmd) {
        if (!mounted) return;
        _handleHardwareCommand(cmd);
      }),
      _liveSession.onError.listen((msg) {
        if (!mounted) return;
        if (msg.contains('autenticacion') || msg.contains('token') ||
            msg.contains('auth') || msg.contains('401') || msg.contains('403')) {
          _stopSession();
          ref.read(firebaseServiceProvider).signOut();
          return;
        }
        _showMessage('Asistente: $msg');
      }),
    ]);

    await _liveSession.connect(token);
    unawaited(_startLocationUpdates());
  }

  /// Inicia el streaming continuo de audio hacia Gemini.
  /// El VAD lo gestiona Gemini automáticamente — no hay lógica de VAD en el cliente.
  void _startStreaming() {
    _setStateIfMounted(AssistantState.listening);
    _audioStreamSub?.cancel();
    _amplitudeSub?.cancel();
    _bargeInStartedAt = null;
    _agentSpeechStartedAt = null;
    _agentAudioActive = false;

    unawaited(_audio.startStreamingRecording(intervalMs: 200));

    _amplitudeSub = _audio.amplitudeStream().listen(_handleAmplitudeSample);
    _audioStreamSub = _audio.audioChunkStream.listen((base64Chunk) {
      if (
          _liveSession.state == LiveSessionState.connected &&
          _shouldForwardAudioChunk()) {
        _liveSession.sendAudioChunk(audioBase64: base64Chunk);
      }
    });
  }

  void _handleAmplitudeSample(Amplitude amp) {
    final now = DateTime.now();
    final currentDb = amp.current;
    _lastAmplitudeDb = currentDb;

    if (!_agentAudioActive) {
      _bargeInStartedAt = null;
      return;
    }

    final graceElapsed = _agentSpeechStartedAt != null &&
        now.difference(_agentSpeechStartedAt!).inMilliseconds >=
            _agentSpeechGraceMs;
    final bargeInDetected = currentDb >= _bargeInThresholdDb;
    if (!graceElapsed) {
      _bargeInStartedAt = null;
      return;
    }

    if (bargeInDetected) {
      _bargeInStartedAt ??= now;
      if (now.difference(_bargeInStartedAt!).inMilliseconds >= _minBargeInMs) {
        if (_bargeInEnabled) {
          debugPrint('[Camera] Barge-in sostenido detectado. Cortando agente.');
          _stopSpeaking();
        }
      }
      return;
    }

    _bargeInStartedAt = null;
  }

  bool _shouldForwardAudioChunk() {
    if (!_agentAudioActive) return true;
    if (_conversationProfile == 'Interrupcion facil') return true;
    return false;
  }

  void _markAgentSpeechActive() {
    _agentSpeechStartedAt ??= DateTime.now();
    _agentAudioActive = true;
    _agentSpeechIdleTimer?.cancel();
    _agentSpeechIdleTimer = Timer(
      const Duration(milliseconds: 7000),
      _handleAgentSpeechEnded,
    );
  }

  void _handleAgentSpeechEnded() {
    _agentSpeechIdleTimer?.cancel();
    _agentAudioActive = false;
    _bargeInStartedAt = null;
    _agentSpeechStartedAt = null;
    if (_state != AssistantState.inactive) {
      _setStateIfMounted(AssistantState.listening);
    }
  }

  Future<void> _startLocationUpdates() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;

      Future<void> sendGps() async {
        try {
          final pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
          ).timeout(const Duration(seconds: 8));
          _liveSession.sendLocation(
            latitude: pos.latitude,
            longitude: pos.longitude,
            accuracy: pos.accuracy,
          );
        } catch (_) {}
      }

      unawaited(sendGps());
      _locationTimer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(sendGps()));
    } catch (_) {}
  }

  void _handleHardwareCommand(Map<String, dynamic> cmd) async {
    final action = cmd['action'] as String?;
    if (action == 'flashlight') {
      final enabled = cmd['enabled'] as bool? ?? false;
      try {
        if (enabled) {
          await TorchLight.enableTorch();
        } else {
          await TorchLight.disableTorch();
        }
      } catch (_) {}
    } else if (action == 'switch_camera') {
      final direction = cmd['direction'] as String?;
      if (direction == 'front') {
        await _switchCamera(CameraLensDirection.front);
      } else if (direction == 'back') {
        await _switchCamera(CameraLensDirection.back);
      }
    } else if (action == 'vibrate') {
      final pattern = cmd['pattern'] as String? ?? 'success';
      if (await Vibration.hasVibrator()) {
        if (pattern == 'success') Vibration.vibrate(duration: 100);
        if (pattern == 'warning') Vibration.vibrate(pattern: [0, 100, 50, 100]);
        if (pattern == 'error') Vibration.vibrate(pattern: [0, 500]);
        if (pattern == 'heavy') Vibration.vibrate(duration: 500);
      }
    }
  }

  Future<String?> _captureFrame() async {
    if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized) {
      return null;
    }
    try {
      final file = await _cameraCtrl!.takePicture().timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw TimeoutException('takePicture timeout'),
      );
      final bytes = await File(file.path).readAsBytes();
      return base64Encode(bytes);
    } catch (e) {
      debugPrint('[Camera] capture error: $e');
      return null;
    }
  }

  void _stopSpeaking() {
    _pcmAudio.stop();
    _handleAgentSpeechEnded();
  }

  void _stopSession() {
    _audioStreamSub?.cancel();
    _audioStreamSub = null;
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    _locationTimer?.cancel();
    _locationTimer = null;
    _agentSpeechIdleTimer?.cancel();
    _agentSpeechIdleTimer = null;
    _bargeInStartedAt = null;
    _agentSpeechStartedAt = null;
    _agentAudioActive = false;
    unawaited(_audio.stopRecording());

    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();

    _pcmAudio.stop();
    _liveSession.disconnect();
    _setStateIfMounted(AssistantState.inactive);
  }

  void _setStateIfMounted(AssistantState newState) {
    if (!mounted || _state == newState) return;
    if (_conversationProfile == 'Interrupcion facil' || newState == AssistantState.inactive) {
      _triggerStateHaptics(newState);
    }
    setState(() => _state = newState);
  }

  Future<void> _triggerStateHaptics(AssistantState state) async {
    try {
      if (state == AssistantState.listening) {
        await Vibration.vibrate(duration: 50, amplitude: 64);
      }
    } catch (_) {}
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _toggleFlashLocally() async {
    if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized) return;
    try {
      final newMode = _cameraCtrl!.value.flashMode == FlashMode.torch
          ? FlashMode.off
          : FlashMode.torch;
      await _cameraCtrl!.setFlashMode(newMode);
      setState(() {});
    } catch (_) {}
  }

  void _openFineTuningPanel() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, modalSetState) {
            void updateSettings(VoidCallback update) {
              modalSetState(update);
              setState(() {});
              unawaited(_persistConversationSettings());
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Ajuste fino de voz',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _CalibrationChip(
                            label: 'Equilibrado',
                            isSelected: _conversationProfile == 'Equilibrado',
                            onTap: () => updateSettings(() { _applyConversationProfile('Equilibrado'); }),
                          ),
                          _CalibrationChip(
                            label: 'Evitar cortes',
                            isSelected: _conversationProfile == 'Evitar cortes',
                            onTap: () => updateSettings(() { _applyConversationProfile('Evitar cortes'); }),
                          ),
                          _CalibrationChip(
                            label: 'Mas rapido',
                            isSelected: _conversationProfile == 'Mas rapido',
                            onTap: () => updateSettings(() { _applyConversationProfile('Mas rapido'); }),
                          ),
                          _CalibrationChip(
                            label: 'Interrupcion facil',
                            isSelected: _conversationProfile == 'Interrupcion facil',
                            onTap: () => updateSettings(() { _applyConversationProfile('Interrupcion facil'); }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _SettingSlider(
                        label: 'Sensibilidad escucha',
                        valueLabel: '${_vadThresholdDb.toStringAsFixed(0)} dB',
                        value: _vadThresholdDb,
                        min: -80, max: -35, divisions: 45,
                        onChanged: (value) => updateSettings(() { _vadThresholdDb = value; }),
                      ),
                      _SettingSlider(
                        label: 'Silencio fin de turno',
                        valueLabel: '${_silenceMs} ms',
                        value: _silenceMs.toDouble(),
                        min: 300, max: 1400, divisions: 22,
                        onChanged: (value) => updateSettings(() { _silenceMs = value.round(); }),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _applyConversationProfile(String profile) {
    _conversationProfile = profile;
    switch (profile) {
      case 'Evitar cortes':
        _vadThresholdDb = -66; _silenceMs = 800; _minRecordMs = 500; _minBargeInMs = 2000; _agentSpeechGraceMs = 1800;
        break;
      case 'Mas rapido':
        _vadThresholdDb = -70; _silenceMs = 450; _minRecordMs = 300; _minBargeInMs = 2000; _agentSpeechGraceMs = 700;
        break;
      case 'Interrupcion facil':
        _vadThresholdDb = -68; _bargeInThresholdDb = -16; _silenceMs = 650; _minRecordMs = 400; _minBargeInMs = 500; _agentSpeechGraceMs = 500;
        break;
      default:
        _vadThresholdDb = _defaultVadThresholdDb; _silenceMs = _defaultSilenceMs; _minRecordMs = _defaultMinRecordMs; _minBargeInMs = 2000; _agentSpeechGraceMs = 1200;
        break;
    }
  }

  Future<File> _settingsFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_settingsFileName');
  }

  Future<void> _loadConversationSettings() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _conversationProfile = json['conversationProfile'] as String? ?? 'Equilibrado';
        _vadThresholdDb = (json['vadThresholdDb'] as num?)?.toDouble() ?? _defaultVadThresholdDb;
        _silenceMs = (json['silenceMs'] as num?)?.round() ?? _defaultSilenceMs;
      });
    } catch (_) {}
  }

  Future<void> _persistConversationSettings() async {
    try {
      final file = await _settingsFile();
      await file.writeAsString(jsonEncode({
        'conversationProfile': _conversationProfile,
        'vadThresholdDb': _vadThresholdDb,
        'silenceMs': _silenceMs,
      }));
    } catch (_) {}
  }

  void _openCalibrationAssistant() {
    // Implementación simplificada para mantener brevedad
  }

  @override
  void dispose() {
    _audioStreamSub?.cancel();
    _amplitudeSub?.cancel();
    _locationTimer?.cancel();
    _agentSpeechIdleTimer?.cancel();
    for (final sub in _subs) sub.cancel();
    _liveSession.disconnect();
    _liveSession.dispose();
    _audio.dispose();
    _pcmAudio.dispose();
    _cameraCtrl?.dispose();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    super.dispose();
  }

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
          _buildBottomControlBar(colors),
        ],
      ),
    );
  }

  Widget _buildGeminiAura(ColorScheme colors) {
    Color auraColor;
    switch (_state) {
      case AssistantState.listening: auraColor = colors.secondary.withValues(alpha: 0.30); break;
      case AssistantState.speaking: auraColor = Colors.cyanAccent.withValues(alpha: 0.38); break;
      case AssistantState.inactive: auraColor = colors.primary.withValues(alpha: 0.14); break;
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: [auraColor, Colors.black.withValues(alpha: 0.82), Colors.black],
          center: Alignment.center, radius: 1.2,
        ),
      ),
    );
  }

  Widget _buildCameraPreview(Size size) {
    return Center(
      child: Container(
        width: size.width * 0.92,
        height: size.height * 0.62,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 20)],
        ),
        clipBehavior: Clip.antiAlias,
        child: (_cameraCtrl != null && _cameraCtrl!.value.isInitialized)
            ? CameraPreview(_cameraCtrl!)
            : Container(color: Colors.grey[900], child: const Icon(Icons.camera_alt, color: Colors.white24, size: 64)),
      ),
    );
  }

  Widget _buildTopOverlay() {
    return Positioned(
      top: 40, left: 20, right: 20,
      child: Row(
        children: [
          _StatusBadge(state: _state),
          const Spacer(),
          _CircleButton(icon: Icons.tune_rounded, onTap: _openFineTuningPanel),
          const SizedBox(width: 10),
          _CircleButton(
            icon: _cameraCtrl?.value.flashMode == FlashMode.torch ? Icons.flashlight_on : Icons.flashlight_off,
            onTap: _toggleFlashLocally,
          ),
          const SizedBox(width: 10),
          _CircleButton(icon: Icons.logout_rounded, onTap: _signOut),
        ],
      ),
    );
  }

  Widget _buildBottomControlBar(ColorScheme colors) {
    return Positioned(
      left: 20, right: 20, bottom: 34,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          boxShadow: [BoxShadow(color: colors.primary.withValues(alpha: 0.15), blurRadius: 24)],
        ),
        child: Row(
          children: [
            _buildAiActionButton(colors),
            const Spacer(),
            _buildStateSpecificContent(colors),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildAiActionButton(ColorScheme colors) {
    final isActive = _state != AssistantState.inactive;
    return GestureDetector(
      onTap: isActive ? _stopSession : _startSession,
      child: Container(
        width: 56, height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [colors.primary, colors.secondary], begin: Alignment.topLeft, end: Alignment.bottomRight),
          boxShadow: [BoxShadow(color: colors.primary.withValues(alpha: 0.3), blurRadius: 12)],
        ),
        child: Icon(isActive ? Icons.stop_rounded : Icons.auto_awesome, color: Colors.white, size: 28),
      ),
    );
  }

  Widget _buildStateSpecificContent(ColorScheme colors) {
    switch (_state) {
      case AssistantState.listening: return _ListeningWave(anim: _pulseAnim);
      case AssistantState.speaking: return _SpeakingWave(anim: _waveAnim, colors: colors);
      case AssistantState.inactive: return const _IdleGlyph();
    }
  }

  Future<void> _signOut() async {
    _stopSession();
    await ref.read(firebaseServiceProvider).signOut();
  }
}

class _SpeakingWave extends StatelessWidget {
  final Animation<double> anim;
  final ColorScheme colors;
  const _SpeakingWave({required this.anim, required this.colors});
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(5, (i) {
          final phase = i / 4.0 * pi;
          final height = 10.0 + 20.0 * ((sin(anim.value * pi + phase) + 1) / 2);
          return Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Container(width: 4, height: height, decoration: BoxDecoration(color: colors.secondary, borderRadius: BorderRadius.circular(2))));
        }),
      ),
    );
  }
}

class _ListeningWave extends StatelessWidget {
  final Animation<double> anim;
  const _ListeningWave({required this.anim});
  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: anim, child: const Icon(Icons.hearing_rounded, color: Colors.white70, size: 30));
  }
}

class _StatusBadge extends StatelessWidget {
  final AssistantState state;
  const _StatusBadge({required this.state});
  @override
  Widget build(BuildContext context) {
    Color color = state == AssistantState.listening ? Colors.greenAccent : (state == AssistantState.speaking ? Colors.cyanAccent : Colors.white24);
    return Container(
      width: 48, height: 48,
      decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle, border: Border.all(color: Colors.white10)),
      child: Center(child: Icon(state == AssistantState.listening ? Icons.hearing_rounded : (state == AssistantState.speaking ? Icons.graphic_eq_rounded : Icons.power_settings_new_rounded), color: Colors.white, size: 20)),
    );
  }
}

class _IdleGlyph extends StatelessWidget {
  const _IdleGlyph();
  @override
  Widget build(BuildContext context) {
    return const Icon(Icons.keyboard_voice_rounded, color: Colors.white54, size: 24);
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleButton({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(width: 44, height: 44, decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle, border: Border.all(color: Colors.white24)), child: Icon(icon, color: Colors.white, size: 22)),
    );
  }
}

class _SettingSlider extends StatelessWidget {
  final String label, valueLabel;
  final double value, min, max;
  final int divisions;
  final ValueChanged<double> onChanged;
  const _SettingSlider({required this.label, required this.valueLabel, required this.value, required this.min, required this.max, required this.divisions, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [Expanded(child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14))), Text(valueLabel, style: const TextStyle(color: Colors.white70, fontSize: 12))]),
        Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged),
      ],
    );
  }
}

class _CalibrationChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  const _CalibrationChip({required this.label, required this.isSelected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? Colors.white.withValues(alpha: 0.70)
                : Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 12)),
      ),
    );
  }
}
