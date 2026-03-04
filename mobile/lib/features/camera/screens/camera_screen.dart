import 'dart:async';
import 'dart:ui'; // Necesario para BackdropFilter e ImageFilter
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/providers/firebase_providers.dart';
import '../../../core/services/audio_service.dart';
import '../../../core/services/live_session_service.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/services/pcm_audio_service.dart';
import 'package:torch_light/torch_light.dart';
import 'package:vibration/vibration.dart';
import 'package:record/record.dart' show Amplitude;

// ─── Máquina de estados del asistente ────────────────────────────────────────

enum AssistantState { inactive, listening, recording, processing, speaking }

// ─── Pantalla principal ────────────────────────────────────────────────────

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen>
    with TickerProviderStateMixin {
  // Cámara
  CameraController? _cameraCtrl;

  // Servicios
  final LiveSessionService _liveSession = LiveSessionService();
  final TtsService _tts = TtsService();
  final AudioService _audio = AudioService();
  final PcmAudioService _pcmAudio = PcmAudioService();

  // Estado
  AssistantState _state = AssistantState.inactive;
  String _conversationId = '';
  String _transcription = ''; // lo que dijo el usuario
  String _geminiText = ''; // respuesta acumulada (streaming + final)
  String? _navigationInstruction; // Instrucción de navegación actual
  Uint8List? _lastFrameBytes; // último frame capturado para mostrar en pantalla

  // VAD (Voice Activity Detection)
  static const double _vadThresholdDb = -35.0;
  static const int _silenceMs = 1500;
  static const int _minRecordMs = 600;
  static const int _maxRecordMs = 15000;
  int _proactiveIntervalSec = 10;

  bool _isVoiceActive = false;
  DateTime? _voiceStartTime;
  DateTime? _silenceStartTime;
  DateTime? _lastInteractionTime;
  StreamSubscription<dynamic>? _amplitudeSub;
  Timer? _proactiveTimer;

  // Subs WebSocket
  final List<StreamSubscription<dynamic>> _subs = [];

  // Animaciones
  late AnimationController _pulseCtrl;
  late AnimationController _waveCtrl;
  late Animation<double> _pulseAnim;
  late Animation<double> _waveAnim;

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

    _pulseAnim = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _waveAnim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _waveCtrl, curve: Curves.easeInOut),
    );
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    // ResolutionPreset.low (~480x640): suficiente para que Gemini entienda
    // la escena y reduce latencia al enviar menos datos.
    _cameraCtrl = CameraController(
      cameras.first,
      ResolutionPreset.low,
      enableAudio: false,
    );
    await _cameraCtrl!.initialize();
    if (mounted) setState(() {});
  }

  // ─── Iniciar sesión conversacional ────────────────────────────────────────

  Future<void> _startSession() async {
    final hasPerm = await _audio.hasPermission;
    if (!hasPerm) {
      _showMessage('Necesito permiso de micrófono');
      return;
    }

    final firebase = ref.read(firebaseServiceProvider);
    final token = await firebase.getIdToken();
    if (token == null) return;

    _conversationId = const Uuid().v4();
    _lastInteractionTime = DateTime.now();
    await _pcmAudio.init();
    _setStateIfMounted(AssistantState.listening);

    _subs.addAll([
      _liveSession.onStateChange.listen((s) {
        if (!mounted) return;
        if (s == LiveSessionState.connected) _startListening();
        if (s == LiveSessionState.error)
          _setStateIfMounted(AssistantState.inactive);
      }),
      _liveSession.onTranscription.listen((text) {
        if (!mounted) return;
        setState(() {
          _transcription = text;
          _geminiText = '';
        });
        _lastInteractionTime = DateTime.now();
      }),
      _liveSession.onChunk.listen((chunk) {
        if (!mounted) return;
        setState(() => _geminiText += chunk);
      }),
      _liveSession.onAudioChunk.listen((base64Audio) {
        if (!mounted) return;
        _setStateIfMounted(AssistantState.speaking);
        // Enviar el chunk de audio directamente al buffer PCM
        _pcmAudio.feedBase64(base64Audio);
      }),
      _liveSession.onInterruption.listen((_) {
        if (!mounted) return;
        debugPrint('Interrupción detectada por Gemini');
        _stopSpeaking();
      }),
      _liveSession.onDone.listen((text) {
        if (!mounted) return;
        // La sesión Live API ya ha enviado todo el audio/texto
        _startListening();
      }),
      _liveSession.onCommand.listen((cmd) {
        if (!mounted) return;
        _handleHardwareCommand(cmd);
      }),
    ]);

    await _liveSession.connect(token);
  }

  // ─── Escucha continua con VAD ──────────────────────────────────────────────

  void _startListening() {
    _setStateIfMounted(AssistantState.listening);
    _isVoiceActive = false;
    _voiceStartTime = null;
    _silenceStartTime = null;

    _amplitudeSub?.cancel();
    _amplitudeSub = _audio.amplitudeStream().listen(_processAmplitude);

    _startProactiveTimer();
  }

  void _processAmplitude(Amplitude amp) {
    if (_state != AssistantState.listening &&
        _state != AssistantState.recording) return;

    final now = DateTime.now();
    final isSpeaking = amp.current > _vadThresholdDb;

    if (isSpeaking) {
      _silenceStartTime = null;
      if (!_isVoiceActive) {
        _isVoiceActive = true;
        _voiceStartTime = now;
        _setStateIfMounted(AssistantState.recording);
        _proactiveTimer?.cancel();
        _audio.startRecording();
      }
    } else {
      if (_isVoiceActive) {
        _silenceStartTime ??= now;
        final silenceDuration =
            now.difference(_silenceStartTime!).inMilliseconds;
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
  }

  Future<void> _sendVoiceFrame() async {
    _amplitudeSub?.cancel();
    _setStateIfMounted(AssistantState.processing);

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
    } catch (_) {
      _startListening();
    }
  }

  void _handleHardwareCommand(Map<String, dynamic> cmd) async {
    final action = cmd['action'] as String;
    if (action == 'flashlight') {
      final enabled = cmd['enabled'] as bool;
      try {
        if (enabled) {
          await TorchLight.enableTorch();
        } else {
          await TorchLight.disableTorch();
        }
      } catch (_) {}
    } else if (action == 'vibrate') {
      final pattern = cmd['pattern'] as String;
      if (await Vibration.hasVibrator() ?? false) {
        if (pattern == 'success') Vibration.vibrate(duration: 100);
        if (pattern == 'warning') Vibration.vibrate(pattern: [0, 100, 50, 100]);
        if (pattern == 'error') Vibration.vibrate(pattern: [0, 500]);
        if (pattern == 'heavy') Vibration.vibrate(duration: 500);
      }
    }
  }

  // ─── Descripción proactiva ─────────────────────────────────────────────────

  void _startProactiveTimer() {
    _proactiveTimer?.cancel();
    _proactiveTimer = Timer.periodic(
      Duration(seconds: _proactiveIntervalSec),
      (_) async {
        if (_state != AssistantState.listening) return;
        final sinceLastInteraction = DateTime.now()
            .difference(_lastInteractionTime ?? DateTime.now())
            .inSeconds;
        if (sinceLastInteraction < _proactiveIntervalSec) return;

        final frame = await _captureFrame();
        if (frame == null || !mounted) return;
        _setStateIfMounted(AssistantState.processing);
        _liveSession.sendFrame(
          conversationId: _conversationId,
          frameBase64: frame,
          prompt:
              'Describe brevemente lo que ves como si fueras los ojos de alguien que no puede ver. Sé conciso y natural.',
        );
      },
    );
  }

  /// Captura un frame con la cámara (ResolutionPreset.low → ~30-80 KB JPEG),
  /// guarda los bytes para mostrarlo en pantalla y retorna el base64.
  Future<String?> _captureFrame() async {
    if (_cameraCtrl == null || !_cameraCtrl!.value.isInitialized) return null;
    try {
      final file = await _cameraCtrl!.takePicture();
      final bytes = await File(file.path).readAsBytes();
      if (mounted) setState(() => _lastFrameBytes = bytes);
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }

  // ─── TTS ──────────────────────────────────────────────────────────────────

  Future<void> _playAudioChunk(String base64Audio) async {
    // Nota: Para el hackathon, si no hay un plugin de reproducción LPCM rápido,
    // se podría usar una cola de bytes. Aquí asumo que ttsService o un similar
    // puede manejarlo o que simplemente mostramos el texto mientras el audio fluye.
    // _audioPlayer.play(BytesSource(base64Decode(base64Audio)));
  }

  void _stopSpeaking() {
    _tts.stop();
    _pcmAudio.stop();
    _setStateIfMounted(AssistantState.listening);
  }

  Future<void> _speakResponse(String text) async {
    // Este método era para el flujo antiguo REST. En Live API, el audio viene por stream.
    if (_state == AssistantState.inactive) return;
    _setStateIfMounted(AssistantState.speaking);
    _lastInteractionTime = DateTime.now();
    await _tts.speak(text);
    _startListening();
  }

  // ─── Detener sesión ───────────────────────────────────────────────────────

  void _stopSession() {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    _proactiveTimer?.cancel();
    _proactiveTimer = null;
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _tts.stop();
    _liveSession.disconnect();
    _setStateIfMounted(AssistantState.inactive);
  }

  void _setStateIfMounted(AssistantState newState) {
    if (!mounted || _state == newState) return;

    // Feedback háptico al cambiar de estado para accesibilidad
    _triggerStateHaptics(newState);

    setState(() => _state = newState);
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
          // No haptics needed here, audio is enough
          break;
        default:
          break;
      }
    } catch (_) {}
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _amplitudeSub?.cancel();
    _proactiveTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _liveSession.disconnect();
    _liveSession.dispose();
    _tts.dispose();
    _audio.dispose();
    _pcmAudio.dispose();
    _cameraCtrl?.dispose();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    super.dispose();
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────

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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Aura de Gemini (Fondo Animado)
          _buildGeminiAura(colors),

          // 2. Preview de la Cámara (con bordes redondeados y sombra)
          _buildCameraPreview(size),

          // 3. Capa de Glassmorphism Superior (Status & Info)
          _buildTopOverlay(colors),

          // 4. Capa de Glassmorphism Inferior (Transcripción & Wave)
          _buildBottomOverlay(size, colors),

          // 5. Botón de Acción Principal (Flotante y Heroico)
          _buildMainActionButton(colors),
        ],
      ),
    );
  }

  Widget _buildGeminiAura(ColorScheme colors) {
    Color auraColor;
    switch (_state) {
      case AssistantState.listening:
        auraColor = colors.secondary.withValues(alpha: 0.3);
        break;
      case AssistantState.recording:
        auraColor = Colors.redAccent.withValues(alpha: 0.4);
        break;
      case AssistantState.processing:
        auraColor = colors.primary.withValues(alpha: 0.5);
        break;
      case AssistantState.speaking:
        auraColor = Colors.cyanAccent.withValues(alpha: 0.4);
        break;
      default:
        auraColor = Colors.transparent;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: [
            auraColor,
            Colors.black,
          ],
          center: Alignment.center,
          radius: _state == AssistantState.processing ? 1.5 : 1.0,
        ),
      ),
    );
  }

  Widget _buildCameraPreview(Size size) {
    return Semantics(
      label: 'Vista previa de la cámara para asistencia visual',
      child: Center(
        child: Container(
          width: size.width * 0.92,
          height: size.height * 0.65,
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
                  child: const Icon(Icons.camera_alt,
                      color: Colors.white24, size: 64),
                ),
        ),
      ),
    );
  }

  Widget _buildTopOverlay(ColorScheme colors) {
    return Positioned(
      top: 60,
      left: 20,
      right: 20,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                _StatusIndicator(state: _state),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _state == AssistantState.inactive
                        ? 'hiBOB Desconectado'
                        : 'hiBOB en línea',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                _CircleButton(
                  icon: _cameraCtrl?.value.flashMode == FlashMode.torch
                      ? Icons.flashlight_on
                      : Icons.flashlight_off,
                  onTap: () => _toggleFlashLocally(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomOverlay(Size size, ColorScheme colors) {
    return Positioned(
      bottom: 110,
      left: 20,
      right: 20,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_navigationInstruction != null)
            _NavigationBox(text: _navigationInstruction!, colors: colors),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  border: Border.all(color: Colors.white10),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  children: [
                    if (_transcription.isNotEmpty)
                      Semantics(
                        label: 'Tú dijiste: $_transcription',
                        child: Text(
                          _transcription,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 14),
                        ),
                      ),
                    const SizedBox(height: 12),
                    _buildStateSpecificContent(colors),
                    const SizedBox(height: 12),
                    _IntervalSlider(
                      value: _proactiveIntervalSec,
                      onChanged: (v) {
                        setState(() => _proactiveIntervalSec = v);
                        if (_state == AssistantState.listening)
                          _startProactiveTimer();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
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
      default:
        return const Text('Presiona el botón para comenzar',
            style: TextStyle(color: Colors.white54));
    }
  }

  Widget _buildMainActionButton(ColorScheme colors) {
    return Positioned(
      bottom: 30,
      left: 0,
      right: 0,
      child: Center(
        child: Semantics(
          button: true,
          label: _state == AssistantState.inactive
              ? 'Iniciar asistente'
              : 'Detener asistente',
          child: GestureDetector(
            onTap: _state == AssistantState.inactive
                ? _startSession
                : _stopSession,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [colors.primary, colors.secondary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: colors.primary.withValues(alpha: 0.4),
                    blurRadius: 15,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(
                _state == AssistantState.inactive
                    ? Icons.power_settings_new
                    : Icons.stop,
                color: Colors.white,
                size: 32,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Widget: burbuja de diálogo ────────────────────────────────────────────────

class _SpeechBubble extends StatelessWidget {
  final String text;
  final bool isUser;
  final ColorScheme colors;
  final bool isStreaming;

  const _SpeechBubble({
    required this.text,
    required this.isUser,
    required this.colors,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? colors.primaryContainer.withValues(alpha: 0.92)
              : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: Border.all(
            color: isUser
                ? colors.primary.withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  color: isUser ? colors.onPrimaryContainer : Colors.white,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
            ),
            if (isStreaming) ...[
              const SizedBox(width: 6),
              const _BlinkingCursor(color: Colors.white70),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Widget: cursor parpadeante ────────────────────────────────────────────────

class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({required this.color});

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _ctrl,
      child: Container(
        width: 2,
        height: 14,
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(1),
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
      builder: (_, __) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(7, (i) {
          final phase = i / 6.0 * pi;
          final height = 8.0 + 22.0 * ((sin(anim.value * pi + phase) + 1) / 2);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Container(
              width: 4,
              height: height,
              decoration: BoxDecoration(
                color: colors.secondary, // Cyan en el nuevo tema
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
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
    return ScaleTransition(
      scale: anim,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mic_none_rounded, color: Colors.white60, size: 36),
          SizedBox(height: 6),
          Text('Escuchando…',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
        ],
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
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mic_rounded, color: Colors.redAccent, size: 40),
          SizedBox(height: 6),
          Text(
            'Grabando…',
            style: TextStyle(
                color: Colors.redAccent,
                fontSize: 13,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

// ─── Componentes auxiliares Heroicos ──────────────────────────────────────────

class _StatusIndicator extends StatelessWidget {
  final AssistantState state;
  const _StatusIndicator({required this.state});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (state) {
      case AssistantState.listening:
        color = Colors.greenAccent;
        break;
      case AssistantState.recording:
        color = Colors.redAccent;
        break;
      case AssistantState.processing:
        color = Colors.purpleAccent;
        break;
      case AssistantState.speaking:
        color = Colors.cyanAccent;
        break;
      default:
        color = Colors.white24;
    }
    return Container(
      width: 10,
      height: 10,
      decoration:
          BoxDecoration(shape: BoxShape.circle, color: color, boxShadow: [
        BoxShadow(
            color: color.withValues(alpha: 0.5),
            blurRadius: 4,
            spreadRadius: 1),
      ]),
    );
  }
}

class _CyberSpinner extends StatelessWidget {
  const _CyberSpinner();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.purpleAccent),
          ),
        ),
        SizedBox(height: 12),
        Text('Procesando...',
            style: TextStyle(color: Colors.white70, fontSize: 14)),
      ],
    );
  }
}

// ─── Widget: botón principal ───────────────────────────────────────────────────

class _MainButton extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;
  final ColorScheme colors;

  const _MainButton({
    required this.isActive,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton.icon(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor:
              isActive ? colors.errorContainer : colors.primaryContainer,
          foregroundColor:
              isActive ? colors.onErrorContainer : colors.onPrimaryContainer,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        icon: Icon(
            isActive ? Icons.stop_rounded : Icons.spatial_audio_off_rounded,
            size: 22),
        label: Text(
          isActive ? 'Detener' : 'Iniciar conversación',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

// ─── Widget: slider intervalo proactivo ───────────────────────────────────────

class _IntervalSlider extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _IntervalSlider({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, color: Colors.white60, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: Colors.white70,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                value: value.toDouble(),
                min: 3,
                max: 30,
                divisions: 9, // 3, 6, 9, 12, 15, 18, 21, 24, 27, 30
                onChanged: (v) => onChanged(v.round()),
              ),
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              '${value}s',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
// ─── Widget: Indicador de Navegación ──────────────────────────────────────────

class _NavigationBox extends StatelessWidget {
  final String text;
  final ColorScheme colors;

  const _NavigationBox({required this.text, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.secondary, width: 2),
      ),
      child: Row(
        children: [
          Icon(Icons.near_me_rounded,
              color: colors.onSecondaryContainer, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: colors.onSecondaryContainer,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widget: botón circular ───────────────────────────────────────────────────

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
