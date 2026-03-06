import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart' show Amplitude;
import 'package:torch_light/torch_light.dart';
import 'package:uuid/uuid.dart';
import 'package:vibration/vibration.dart';

import '../../../core/providers/firebase_providers.dart';
import '../../../core/services/audio_service.dart';
import '../../../core/services/live_session_service.dart';
import '../../../core/services/pcm_audio_service.dart';

enum AssistantState { inactive, listening, recording, processing, speaking }

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin {
  static const double _vadThresholdDb = -68.0;
  static const double _bargeInThresholdDb = -42.0;
  static const int _silenceMs = 900;
  static const int _minRecordMs = 600;
  static const int _maxRecordMs = 6000;
  static const int _proactiveIntervalSec = 2;

  CameraController? _cameraCtrl;
  List<CameraDescription> _availableCameras = const [];
  CameraLensDirection _selectedLensDirection = CameraLensDirection.back;

  final LiveSessionService _liveSession = LiveSessionService();
  final AudioService _audio = AudioService();
  final PcmAudioService _pcmAudio = PcmAudioService();

  AssistantState _state = AssistantState.inactive;
  String _conversationId = '';

  bool _isVoiceActive = false;
  bool _isProactiveProcessing = false;
  DateTime? _voiceStartTime;
  DateTime? _silenceStartTime;
  DateTime? _lastInteractionTime;
  DateTime? _lastVadDebugAt;

  StreamSubscription<dynamic>? _amplitudeSub;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _proactiveTimer;
  Timer? _processingTimeout;

  late final AnimationController _pulseCtrl;
  late final AnimationController _waveCtrl;
  late final Animation<double> _pulseAnim;
  late final Animation<double> _waveAnim;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _initCamera();
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

    _conversationId = const Uuid().v4();
    _lastInteractionTime = DateTime.now();
    await _pcmAudio.init();

    _subs.addAll([
      _liveSession.onStateChange.listen((s) {
        if (!mounted) return;
        switch (s) {
          case LiveSessionState.connected:
            _startListening();
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
            _setStateIfMounted(AssistantState.processing);
            break;
        }
      }),
      _liveSession.onTranscription.listen((_) {
        if (!mounted) return;
        _processingTimeout?.cancel();
        _startProcessingTimeout();
        _lastInteractionTime = DateTime.now();
      }),
      _liveSession.onAudioChunk.listen((audioChunk) {
        if (!mounted) return;
        _lastInteractionTime = DateTime.now();
        _setStateIfMounted(AssistantState.speaking);
        final base64Audio = audioChunk['data'] ?? '';
        final mimeType = audioChunk['mimeType'];
        _pcmAudio.feedBase64(base64Audio, mimeType: mimeType);
      }),
      _liveSession.onInterruption.listen((_) {
        if (!mounted) return;
        _lastInteractionTime = DateTime.now();
        _stopSpeaking();
      }),
      _liveSession.onDone.listen((_) {
        if (!mounted) return;
        _lastInteractionTime = DateTime.now();
        _processingTimeout?.cancel();
        _startListening();
      }),
      _liveSession.onCommand.listen((cmd) {
        if (!mounted) return;
        _handleHardwareCommand(cmd);
      }),
      _liveSession.onError.listen((msg) {
        if (!mounted) return;
        _processingTimeout?.cancel();
        _showMessage('Asistente: $msg');
        _startListening();
      }),
    ]);

    await _liveSession.connect(token);
  }

  void _startListening() {
    _setStateIfMounted(AssistantState.listening);
    _isVoiceActive = false;
    _voiceStartTime = null;
    _silenceStartTime = null;
    _startVadMonitoring();
    _startProactiveTimer();
  }

  void _startVadMonitoring() {
    _amplitudeSub?.cancel();
    unawaited(_ensureVadRecording());
    _amplitudeSub = _audio.amplitudeStream().listen(_processAmplitude);
  }

  Future<void> _ensureVadRecording() async {
    try {
      final isRecording = await _audio.isRecording;
      if (!isRecording) {
        await _audio.startRecording();
      }
    } catch (e) {
      debugPrint('[VAD] Error starting recording: $e');
    }
  }

  void _processAmplitude(Amplitude amp) {
    if (_state != AssistantState.listening &&
        _state != AssistantState.recording &&
        _state != AssistantState.processing &&
        _state != AssistantState.speaking) {
      return;
    }

    final now = DateTime.now();
    final threshold =
        _state == AssistantState.speaking || _state == AssistantState.processing
            ? _bargeInThresholdDb
            : _vadThresholdDb;

    if (_lastVadDebugAt == null ||
        now.difference(_lastVadDebugAt!).inMilliseconds >= 900) {
      _lastVadDebugAt = now;
      debugPrint(
        '[VAD] amp=${amp.current.toStringAsFixed(1)} dB, threshold=${threshold.toStringAsFixed(1)}, state=$_state',
      );
    }

    final isSpeaking = amp.current > threshold;

    if (_isVoiceActive && _voiceStartTime != null) {
      final recordDuration = now.difference(_voiceStartTime!).inMilliseconds;
      if (recordDuration >= _maxRecordMs) {
        _isVoiceActive = false;
        _sendVoiceFrame();
        return;
      }
    }

    if (isSpeaking) {
      _silenceStartTime = null;
      if (!_isVoiceActive) {
        if (_state == AssistantState.speaking ||
            _state == AssistantState.processing) {
          _stopSpeaking();
        }
        _isVoiceActive = true;
        _voiceStartTime = now;
        _lastInteractionTime = now;
        _setStateIfMounted(AssistantState.recording);
        _proactiveTimer?.cancel();
      }
    } else if (_isVoiceActive && _voiceStartTime != null) {
      _silenceStartTime ??= now;
      final silenceDuration = now.difference(_silenceStartTime!).inMilliseconds;
      final recordDuration = now.difference(_voiceStartTime!).inMilliseconds;

      if (silenceDuration >= _silenceMs && recordDuration >= _minRecordMs) {
        _isVoiceActive = false;
        _sendVoiceFrame();
      } else if (recordDuration >= _maxRecordMs) {
        _isVoiceActive = false;
        _sendVoiceFrame();
      }
    }
  }

  Future<void> _sendVoiceFrame() async {
    if (_liveSession.state != LiveSessionState.connected) {
      _startListening();
      return;
    }

    _setStateIfMounted(AssistantState.processing);
    _startProcessingTimeout();

    try {
      final audioBase64 = await _audio.stopAndGetBase64();
      if (audioBase64 == null || audioBase64.isEmpty) {
        _startListening();
        return;
      }

      final frame = await _captureFrame();
      if (frame == null) {
        _startListening();
        return;
      }

      _liveSession.sendVoiceFrame(
        conversationId: _conversationId,
        frameBase64: frame,
        audioBase64: audioBase64,
      );
      _lastInteractionTime = DateTime.now();
      _isVoiceActive = false;
      _voiceStartTime = null;
      _silenceStartTime = null;
      _startVadMonitoring();
    } catch (e) {
      debugPrint('[Live] sendVoiceFrame error: $e');
      _startListening();
    }
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
    } else if (action == 'vibrate') {
      final pattern = cmd['pattern'] as String? ?? 'success';
      if (await Vibration.hasVibrator() ?? false) {
        if (pattern == 'success') Vibration.vibrate(duration: 100);
        if (pattern == 'warning') Vibration.vibrate(pattern: [0, 100, 50, 100]);
        if (pattern == 'error') Vibration.vibrate(pattern: [0, 500]);
        if (pattern == 'heavy') Vibration.vibrate(duration: 500);
      }
    }
  }

  void _startProactiveTimer() {
    _proactiveTimer?.cancel();
    _proactiveTimer = Timer.periodic(
      Duration(seconds: _proactiveIntervalSec),
      (_) async {
        if (_state != AssistantState.listening || _isProactiveProcessing) return;
        if (_isVoiceActive) return;

        final sinceLastInteraction = DateTime.now()
            .difference(_lastInteractionTime ?? DateTime.now())
            .inSeconds;
        if (sinceLastInteraction < _proactiveIntervalSec) return;
        if (_liveSession.state != LiveSessionState.connected) return;

        _isProactiveProcessing = true;
        try {
          final frame = await _captureFrame();
          if (frame == null || !mounted) return;

          _setStateIfMounted(AssistantState.processing);
          _startProcessingTimeout();
          _liveSession.sendFrame(
            conversationId: _conversationId,
            frameBase64: frame,
          );
          _startVadMonitoring();
        } finally {
          _isProactiveProcessing = false;
        }
      },
    );
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
    if (_state != AssistantState.inactive) {
      _setStateIfMounted(AssistantState.listening);
    }
  }

  void _stopSession() {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    _proactiveTimer?.cancel();
    _proactiveTimer = null;
    _processingTimeout?.cancel();
    _processingTimeout = null;
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

    if (_state == AssistantState.processing &&
        newState != AssistantState.processing) {
      _processingTimeout?.cancel();
    }

    _triggerStateHaptics(newState);
    setState(() => _state = newState);
  }

  void _startProcessingTimeout() {
    _processingTimeout?.cancel();
    _processingTimeout = Timer(const Duration(seconds: 30), () {
      if (_state == AssistantState.processing) {
        _showMessage('El asistente esta tardando demasiado');
        _startListening();
      }
    });
  }

  Future<void> _triggerStateHaptics(AssistantState state) async {
    try {
      switch (state) {
        case AssistantState.listening:
          await Vibration.vibrate(duration: 50, amplitude: 64);
          break;
        case AssistantState.recording:
          await Vibration.vibrate(duration: 100, amplitude: 128);
          break;
        case AssistantState.processing:
          await Vibration.vibrate(pattern: [0, 50, 50, 50]);
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

  @override
  void dispose() {
    _amplitudeSub?.cancel();
    _proactiveTimer?.cancel();
    _processingTimeout?.cancel();
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
          _buildCameraPreview(size),
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
      case AssistantState.recording:
        auraColor = Colors.redAccent.withValues(alpha: 0.36);
        break;
      case AssistantState.processing:
        auraColor = colors.primary.withValues(alpha: 0.42);
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
          radius: _state == AssistantState.processing ? 1.8 : 1.2,
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

  Widget _buildTopOverlay() {
    return Positioned(
      top: 26,
      left: 20,
      right: 20,
      child: Row(
        children: [
          _StatusBadge(state: _state),
          const Spacer(),
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
      case AssistantState.recording:
        return _RecordingIndicator(anim: _pulseAnim, colors: colors);
      case AssistantState.processing:
        return const _CyberSpinner();
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

class _RecordingIndicator extends StatelessWidget {
  final Animation<double> anim;
  final ColorScheme colors;

  const _RecordingIndicator({required this.anim, required this.colors});

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: anim,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.redAccent.withValues(alpha: 0.45),
              blurRadius: 18,
              spreadRadius: 4,
            ),
          ],
        ),
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
      case AssistantState.recording:
        color = Colors.redAccent;
        icon = Icons.mic_rounded;
        break;
      case AssistantState.processing:
        color = Colors.purpleAccent;
        icon = Icons.blur_on_rounded;
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

class _CyberSpinner extends StatelessWidget {
  const _CyberSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 44,
      width: 44,
      child: CircularProgressIndicator(
        strokeWidth: 3,
        valueColor: AlwaysStoppedAnimation<Color>(Colors.purpleAccent),
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
