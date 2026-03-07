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
    // Si el agente no está hablando, siempre enviamos audio continuo
    // para que el VAD de Gemini detecte cuándo empieza el usuario.
    if (!_agentAudioActive) return true;

    // Si el agente está hablando:
    // 1. En perfil 'Interrupcion facil', enviamos todo para permitir barge-in nativo.
    if (_conversationProfile == 'Interrupcion facil') return true;

    // 2. En perfiles estables (Equilibrado, Evitar cortes, Mas rapido), 
    // suprimimos el audio del micro mientras el agente habla. Esto evita que 
    // el eco del altavoz dispare el VAD de Gemini y corte la respuesta.
    return false;
  }

  void _markAgentSpeechActive() {
    _agentSpeechStartedAt ??= DateTime.now();
    _agentAudioActive = true;
    // Reiniciar el timer cada vez que llega un chunk. Si no llega nada en
    // 1500ms consideramos que el agente terminó de hablar. Este valor alto
    // evita que el gap natural entre chunks PCM dispare un falso "fin de turno"
    // que haría que el cliente enviara audio y Gemini se interrumpiera a sí mismo.
    _agentSpeechIdleTimer?.cancel();
    _agentSpeechIdleTimer = Timer(
      const Duration(milliseconds: 1500),
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
    } else if (action == 'flashlight') {
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
    _triggerStateHaptics(newState);
    setState(() => _state = newState);
  }

  Future<void> _triggerStateHaptics(AssistantState state) async {
    try {
      switch (state) {
        case AssistantState.listening:
          await Vibration.vibrate(duration: 50, amplitude: 64);
          break;
        case AssistantState.speaking:
        case AssistantState.inactive:
          break;
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
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Calibracion de conversacion',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _CalibrationChip(
                            label: 'Equilibrado',
                            isSelected: _conversationProfile == 'Equilibrado',
                            onTap: () => updateSettings(() {
                              _applyConversationProfile('Equilibrado');
                            }),
                          ),
                          _CalibrationChip(
                            label: 'Evitar cortes',
                            isSelected: _conversationProfile == 'Evitar cortes',
                            onTap: () => updateSettings(() {
                              _applyConversationProfile('Evitar cortes');
                            }),
                          ),
                          _CalibrationChip(
                            label: 'Mas rapido',
                            isSelected: _conversationProfile == 'Mas rapido',
                            onTap: () => updateSettings(() {
                              _applyConversationProfile('Mas rapido');
                            }),
                          ),
                          _CalibrationChip(
                            label: 'Interrupcion facil',
                            isSelected:
                                _conversationProfile == 'Interrupcion facil',
                            onTap: () => updateSettings(() {
                              _applyConversationProfile('Interrupcion facil');
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _openCalibrationAssistant();
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.28),
                            ),
                          ),
                          icon: const Icon(Icons.auto_fix_high_rounded),
                          label: const Text('Calibracion guiada'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.10),
                          ),
                        ),
                        child: Text(
                          _conversationProfileHelpText(),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      _SettingSlider(
                        label: 'Sensibilidad escucha',
                        valueLabel: '${_vadThresholdDb.toStringAsFixed(0)} dB',
                        value: _vadThresholdDb,
                        min: -80,
                        max: -35,
                        divisions: 45,
                        onChanged: (value) => updateSettings(() {
                          _vadThresholdDb = value;
                        }),
                      ),
                      if (_bargeInEnabled) ...[
                        _SettingSlider(
                          label: 'Sensibilidad interrupcion',
                          valueLabel:
                              '${_bargeInThresholdDb.toStringAsFixed(0)} dB',
                          value: _bargeInThresholdDb,
                          min: -25,
                          max: 0,
                          divisions: 25,
                          onChanged: (value) => updateSettings(() {
                            _bargeInThresholdDb = value;
                          }),
                        ),
                      ] else ...[
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(top: 6, bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: const Text(
                            'Sensibilidad interrupcion desactivada en este perfil. Solo se usa en "Interrupcion facil".',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                      _SettingSlider(
                        label: 'Silencio fin de turno',
                        valueLabel: '${_silenceMs} ms',
                        value: _silenceMs.toDouble(),
                        min: 300,
                        max: 1400,
                        divisions: 22,
                        onChanged: (value) => updateSettings(() {
                          _silenceMs = value.round();
                        }),
                      ),
                      _SettingSlider(
                        label: 'Minimo de voz',
                        valueLabel: '${_minRecordMs} ms',
                        value: _minRecordMs.toDouble(),
                        min: 250,
                        max: 1200,
                        divisions: 19,
                        onChanged: (value) => updateSettings(() {
                          _minRecordMs = value.round();
                        }),
                      ),
                      if (_bargeInEnabled)
                        _SettingSlider(
                          label: 'Interrupcion sostenida',
                          valueLabel: '${_minBargeInMs} ms',
                          value: _minBargeInMs.toDouble(),
                          min: 300,
                          max: 2000,
                          divisions: 17,
                          onChanged: (value) => updateSettings(() {
                            _minBargeInMs = value.round();
                          }),
                        ),
                      _SettingSlider(
                        label: 'Gracia al empezar a hablar',
                        valueLabel: '${_agentSpeechGraceMs} ms',
                        value: _agentSpeechGraceMs.toDouble(),
                        min: 0,
                        max: 2000,
                        divisions: 20,
                        onChanged: (value) => updateSettings(() {
                          _agentSpeechGraceMs = value.round();
                        }),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => updateSettings(() {
                            _applyConversationProfile('Equilibrado');
                          }),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.28),
                            ),
                          ),
                          child: const Text('Restablecer'),
                        ),
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
        _vadThresholdDb = -66;
        _bargeInThresholdDb = 0;
        _silenceMs = 800;
        _minRecordMs = 500;
        _minBargeInMs = 2000;
        _agentSpeechGraceMs = 1800;
        break;
      case 'Mas rapido':
        _vadThresholdDb = -70;
        _bargeInThresholdDb = 0;
        _silenceMs = 450;
        _minRecordMs = 300;
        _minBargeInMs = 2000;
        _agentSpeechGraceMs = 700;
        break;
      case 'Interrupcion facil':
        _vadThresholdDb = -68;
        _bargeInThresholdDb = -16;
        _silenceMs = 650;
        _minRecordMs = 400;
        _minBargeInMs = 500;
        _agentSpeechGraceMs = 500;
        break;
      case 'Equilibrado':
      default:
        _vadThresholdDb = _defaultVadThresholdDb;
        _bargeInThresholdDb = 0;
        _silenceMs = _defaultSilenceMs;
        _minRecordMs = _defaultMinRecordMs;
        _minBargeInMs = 2000;
        _agentSpeechGraceMs = 1200;
        break;
    }
  }

  String _conversationProfileHelpText() {
    switch (_conversationProfile) {
      case 'Evitar cortes':
        return 'Desactiva en la practica las interrupciones mientras el agente habla. Recomendado si el altavoz dispara cortes falsos.';
      case 'Mas rapido':
        return 'Reduce pausas al terminar cada turno, pero mantiene bloqueada la interrupcion del agente para evitar autocortes.';
      case 'Interrupcion facil':
        return 'Permite cortar al agente al hablarle encima. Es el unico perfil que mantiene el barge-in activo y puede reintroducir autocortes.';
      case 'Equilibrado':
      default:
        return 'Compromiso entre fluidez y estabilidad. El agente termina su frase antes de volver a escuchar.';
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
        _conversationProfile =
            json['conversationProfile'] as String? ?? 'Equilibrado';
        _vadThresholdDb =
            (json['vadThresholdDb'] as num?)?.toDouble() ??
                _defaultVadThresholdDb;
        _bargeInThresholdDb =
            (json['bargeInThresholdDb'] as num?)?.toDouble() ??
                _defaultBargeInThresholdDb;
        _silenceMs = (json['silenceMs'] as num?)?.round() ?? _defaultSilenceMs;
        _minRecordMs =
            (json['minRecordMs'] as num?)?.round() ?? _defaultMinRecordMs;
        _minBargeInMs =
            (json['minBargeInMs'] as num?)?.round() ?? _defaultMinBargeInMs;
        _agentSpeechGraceMs =
            (json['agentSpeechGraceMs'] as num?)?.round() ??
                _defaultAgentSpeechGraceMs;
      });
    } catch (e) {
      debugPrint('[Settings] load error: $e');
    }
  }

  Future<void> _persistConversationSettings() async {
    try {
      final file = await _settingsFile();
      await file.writeAsString(
        jsonEncode({
          'conversationProfile': _conversationProfile,
          'vadThresholdDb': _vadThresholdDb,
          'bargeInThresholdDb': _bargeInThresholdDb,
          'silenceMs': _silenceMs,
          'minRecordMs': _minRecordMs,
          'minBargeInMs': _minBargeInMs,
          'agentSpeechGraceMs': _agentSpeechGraceMs,
        }),
      );
    } catch (e) {
      debugPrint('[Settings] persist error: $e');
    }
  }

  Future<Map<String, double>?> _measureAmbientAudio({
    Duration duration = const Duration(seconds: 6),
  }) async {
    if (_state != AssistantState.inactive) {
      _showMessage('Deten el asistente antes de ejecutar la auto-calibracion');
      return null;
    }

    final hasPermission = await _audio.hasPermission;
    if (!hasPermission) {
      _showMessage('Necesito permiso de microfono para calibrar');
      return null;
    }

    final wasRecording = await _audio.isRecording;
    final samples = <double>[];
    StreamSubscription<Amplitude>? sub;

    try {
      if (!wasRecording) {
        await _audio.startRecording();
      }

      final completer = Completer<void>();
      sub = _audio.amplitudeStream().listen((amp) {
        samples.add(amp.current);
      });

      Timer(duration, () {
        if (!completer.isCompleted) completer.complete();
      });

      await completer.future;
    } catch (e) {
      debugPrint('[Calibration] ambient measure error: $e');
      return null;
    } finally {
      await sub?.cancel();
      if (!wasRecording) {
        await _audio.stopRecording();
      }
    }

    if (samples.isEmpty) return null;

    var sum = 0.0;
    var peak = -160.0;
    var noisyCount = 0;
    for (final sample in samples) {
      sum += sample;
      if (sample > peak) peak = sample;
      if (sample > -45) noisyCount++;
    }

    return {
      'average': sum / samples.length,
      'peak': peak,
      'noisyRatio': noisyCount / samples.length,
    };
  }

  void _applyAutoCalibration(Map<String, double> stats) {
    final average = stats['average'] ?? -70;
    final peak = stats['peak'] ?? -70;
    final noisyRatio = stats['noisyRatio'] ?? 0;

    if (peak > -8 || noisyRatio > 0.22 || average > -48) {
      _applyConversationProfile('Evitar cortes');
      _vadThresholdDb = -62;
      _bargeInThresholdDb = -2;
      _minBargeInMs = 1700;
      _agentSpeechGraceMs = 1700;
      return;
    }

    if (average < -62 && noisyRatio < 0.05) {
      _applyConversationProfile('Mas rapido');
      _vadThresholdDb = -71;
      _silenceMs = 420;
      _minRecordMs = 280;
      return;
    }

    _applyConversationProfile('Equilibrado');
  }

  void _openCalibrationAssistant() {
    var isRunning = false;
    var status =
        'Haz la prueba con el agente parado y en el entorno donde vas a usarlo.';

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, modalSetState) {
            Future<void> runAutoCalibration() async {
              modalSetState(() {
                isRunning = true;
                status =
                    'Escuchando el entorno durante 6 segundos. No hables.';
              });

              final stats = await _measureAmbientAudio();
              if (!context.mounted) return;

              if (stats == null) {
                modalSetState(() {
                  isRunning = false;
                  status =
                      'No se pudo medir el entorno. Revisa permisos y que el asistente este parado.';
                });
                return;
              }

              setState(() {
                _applyAutoCalibration(stats);
              });
              await _persistConversationSettings();

              final average = (stats['average'] ?? 0).toStringAsFixed(1);
              final peak = (stats['peak'] ?? 0).toStringAsFixed(1);
              final profileSummary = switch (_conversationProfile) {
                'Evitar cortes' =>
                  'Perfil aplicado: Evitar cortes. El agente no se dejara interrumpir mientras habla.',
                'Mas rapido' =>
                  'Perfil aplicado: Mas rapido. El agente termina su frase antes de volver a escuchar.',
                'Interrupcion facil' =>
                  'Perfil aplicado: Interrupcion facil. El agente podra cortarse si le hablas encima.',
                _ =>
                  'Perfil aplicado: Equilibrado. El agente termina su frase antes de volver a escuchar.',
              };
              modalSetState(() {
                isRunning = false;
                status =
                    'Auto-calibracion aplicada. Ruido medio: $average dB, pico: $peak dB. $profileSummary';
              });
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Calibracion guiada',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Elige el problema principal o ejecuta una auto-calibracion con el micro para estimar el ruido del entorno.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                        ),
                      ),
                      child: Text(
                        status,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: isRunning ? null : runAutoCalibration,
                        icon: isRunning
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Icon(Icons.mic_external_on_rounded),
                        label: Text(
                          isRunning
                              ? 'Midiendo entorno...'
                              : 'Auto-calibrar con micro',
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    _CalibrationActionCard(
                      title: 'El agente se corta solo',
                      subtitle:
                          'Bloquea la interrupcion mientras el agente habla y protege el inicio de cada respuesta.',
                      onTap: () {
                        setState(() {
                          _applyConversationProfile('Evitar cortes');
                        });
                        unawaited(_persistConversationSettings());
                        Navigator.of(context).pop();
                        _showMessage('Perfil "Evitar cortes" aplicado');
                      },
                    ),
                    _CalibrationActionCard(
                      title: 'Las pausas son demasiado largas',
                      subtitle:
                          'Acelera el cambio de turno, pero el agente seguira terminando su frase antes de escuchar.',
                      onTap: () {
                        setState(() {
                          _applyConversationProfile('Mas rapido');
                        });
                        unawaited(_persistConversationSettings());
                        Navigator.of(context).pop();
                        _showMessage('Perfil "Mas rapido" aplicado');
                      },
                    ),
                    _CalibrationActionCard(
                      title: 'Quiero interrumpir al agente con facilidad',
                      subtitle:
                          'Activa el unico perfil con barge-in real. Puede reintroducir autocortes si el altavoz se cuela en el micro.',
                      onTap: () {
                        setState(() {
                          _applyConversationProfile('Interrupcion facil');
                        });
                        unawaited(_persistConversationSettings());
                        Navigator.of(context).pop();
                        _showMessage('Perfil "Interrupcion facil" aplicado');
                      },
                    ),
                    _CalibrationActionCard(
                      title: 'Volver a una configuracion equilibrada',
                      subtitle:
                          'Restablece el comportamiento recomendado. El agente termina su frase antes de volver a escuchar.',
                      onTap: () {
                        setState(() {
                          _applyConversationProfile('Equilibrado');
                        });
                        unawaited(_persistConversationSettings());
                        Navigator.of(context).pop();
                        _showMessage('Perfil "Equilibrado" aplicado');
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _audioStreamSub?.cancel();
    _amplitudeSub?.cancel();
    _locationTimer?.cancel();
    _agentSpeechIdleTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
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
          _buildBottomOverlay(colors),
          _buildMainActionButton(colors),
        ],
      ),
    );
  }

  Widget _buildGeminiAura(ColorScheme colors) {
    Color auraColor;
    switch (_state) {
      case AssistantState.listening:
        auraColor = colors.secondary.withValues(alpha: 0.30);
        break;
      case AssistantState.speaking:
        auraColor = Colors.cyanAccent.withValues(alpha: 0.38);
        break;
      case AssistantState.inactive:
        auraColor = colors.primary.withValues(alpha: 0.14);
        break;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: [
            auraColor,
            Colors.black.withValues(alpha: 0.82),
            Colors.black,
          ],
          center: Alignment.center,
          radius: 1.2,
        ),
      ),
    );
  }

  Widget _buildCameraPreview(Size size) {
    return Semantics(
      label: 'Vista previa de la camara para asistencia visual',
      child: Center(
        child: Container(
          width: size.width * 0.92,
          height: size.height * 0.67,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: (_cameraCtrl != null && _cameraCtrl!.value.isInitialized)
              ? CameraPreview(_cameraCtrl!)
              : Container(
                  color: Colors.grey[900],
                  child: const Icon(
                    Icons.camera_alt,
                    color: Colors.white24,
                    size: 64,
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _signOut() async {
    _stopSession();
    final firebase = ref.read(firebaseServiceProvider);
    await firebase.signOut();
  }

  Widget _buildTopOverlay() {
    return Positioned(
      top: 26,
      left: 20,
      right: 20,
      child: Row(
        children: [
          _StatusBadge(state: _state),
          const Spacer(),
          _CircleButton(
            icon: Icons.tune_rounded,
            onTap: _openFineTuningPanel,
          ),
          const SizedBox(width: 10),
          _CameraLensButton(
            icon: Icons.camera_rear_rounded,
            isSelected: _selectedLensDirection == CameraLensDirection.back,
            isEnabled: _hasBackCamera,
            onTap: () => _switchCamera(CameraLensDirection.back),
          ),
          const SizedBox(width: 10),
          _CameraLensButton(
            icon: Icons.camera_front_rounded,
            isSelected: _selectedLensDirection == CameraLensDirection.front,
            isEnabled: _hasFrontCamera,
            onTap: () => _switchCamera(CameraLensDirection.front),
          ),
          const SizedBox(width: 10),
          _CircleButton(
            icon: _cameraCtrl?.value.flashMode == FlashMode.torch
                ? Icons.flashlight_on
                : Icons.flashlight_off,
            onTap: _toggleFlashLocally,
          ),
          const SizedBox(width: 10),
          _CircleButton(
            icon: Icons.logout_rounded,
            onTap: _signOut,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomOverlay(ColorScheme colors) {
    return Positioned(
      left: 20,
      right: 20,
      bottom: 132,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.34),
              blurRadius: 18,
              spreadRadius: 2,
            ),
          ],
        ),
        child: _buildStateSpecificContent(colors),
      ),
    );
  }

  Widget _buildStateSpecificContent(ColorScheme colors) {
    switch (_state) {
      case AssistantState.listening:
        return _ListeningWave(anim: _pulseAnim);
      case AssistantState.speaking:
        return _SpeakingWave(anim: _waveAnim, colors: colors);
      case AssistantState.inactive:
        return const _IdleGlyph();
    }
  }

  Widget _buildMainActionButton(ColorScheme colors) {
    return Positioned(
      bottom: 34,
      left: 0,
      right: 0,
      child: Center(
        child: Semantics(
          button: true,
          label: _state == AssistantState.inactive
              ? 'Iniciar asistente en vivo'
              : 'Detener asistente en vivo',
          child: GestureDetector(
            onTap: _state == AssistantState.inactive
                ? _startSession
                : _stopSession,
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [colors.primary, colors.secondary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: colors.primary.withValues(alpha: 0.42),
                    blurRadius: 22,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Icon(
                _state == AssistantState.inactive
                    ? Icons.power_settings_new
                    : Icons.stop_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),
          ),
        ),
      ),
    );
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
      builder: (_, __) => SizedBox(
        height: 56,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(7, (i) {
            final phase = i / 6.0 * pi;
            final height = 10.0 + 24.0 * ((sin(anim.value * pi + phase) + 1) / 2);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Container(
                width: 5,
                height: height,
                decoration: BoxDecoration(
                  color: colors.secondary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _ListeningWave extends StatelessWidget {
  final Animation<double> anim;

  const _ListeningWave({required this.anim});

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: anim,
      child: const Icon(
        Icons.hearing_rounded,
        color: Colors.white70,
        size: 38,
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final AssistantState state;

  const _StatusBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    Color color;
    IconData icon;
    switch (state) {
      case AssistantState.listening:
        color = Colors.greenAccent;
        icon = Icons.hearing_rounded;
        break;
      case AssistantState.speaking:
        color = Colors.cyanAccent;
        icon = Icons.graphic_eq_rounded;
        break;
      case AssistantState.inactive:
        color = Colors.white24;
        icon = Icons.power_settings_new_rounded;
        break;
    }

    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.22),
            blurRadius: 14,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(icon, color: Colors.white, size: 22),
          Positioned(
            right: 11,
            top: 11,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdleGlyph extends StatelessWidget {
  const _IdleGlyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white24),
      ),
      child: const Icon(
        Icons.keyboard_voice_rounded,
        color: Colors.white54,
        size: 28,
      ),
    );
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
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

class _SettingSlider extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _SettingSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                valueLabel,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: Colors.white24,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _CalibrationChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _CalibrationChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isSelected
                ? Colors.white70
                : Colors.white.withValues(alpha: 0.14),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _CalibrationActionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _CalibrationActionCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraLensButton extends StatelessWidget {
  final IconData icon;
  final bool isSelected;
  final bool isEnabled;
  final VoidCallback onTap;

  const _CameraLensButton({
    required this.icon,
    required this.isSelected,
    required this.isEnabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected
        ? Colors.white70
        : Colors.white.withValues(alpha: 0.18);
    final fillColor = isSelected
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.45);

    return GestureDetector(
      onTap: isEnabled ? onTap : null,
      child: Opacity(
        opacity: isEnabled ? 1 : 0.35,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: fillColor,
            shape: BoxShape.circle,
            border: Border.all(color: borderColor),
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
