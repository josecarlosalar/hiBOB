import 'dart:async';
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

  // Estado
  AssistantState _state = AssistantState.inactive;
  String _conversationId = '';
  String _transcription = '';   // lo que dijo el usuario
  String _geminiText = '';      // respuesta acumulada (streaming + final)
  Uint8List? _lastFrameBytes;   // último frame capturado para mostrar en pantalla

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
    _setStateIfMounted(AssistantState.listening);

    _subs.addAll([
      _liveSession.onStateChange.listen((s) {
        if (!mounted) return;
        if (s == LiveSessionState.connected) _startListening();
        if (s == LiveSessionState.error) _setStateIfMounted(AssistantState.inactive);
      }),
      _liveSession.onTranscription.listen((text) {
        if (!mounted) return;
        setState(() { _transcription = text; _geminiText = ''; });
        _lastInteractionTime = DateTime.now();
      }),
      _liveSession.onChunk.listen((chunk) {
        if (!mounted) return;
        setState(() => _geminiText += chunk);
      }),
      _liveSession.onDone.listen((text) {
        if (!mounted) return;
        setState(() => _geminiText = text);
        _speakResponse(text);
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
    if (_state != AssistantState.listening && _state != AssistantState.recording) return;

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
          prompt: 'Describe brevemente lo que ves como si fueras los ojos de alguien que no puede ver. Sé conciso y natural.',
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

  Future<void> _speakResponse(String text) async {
    _setStateIfMounted(AssistantState.speaking);
    _amplitudeSub?.cancel();
    _proactiveTimer?.cancel();
    _lastInteractionTime = DateTime.now();

    await _tts.speak(text);

    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted && _liveSession.state == LiveSessionState.connected) {
      _startListening();
    }
  }

  // ─── Detener sesión ───────────────────────────────────────────────────────

  void _stopSession() {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    _proactiveTimer?.cancel();
    _proactiveTimer = null;
    for (final sub in _subs) { sub.cancel(); }
    _subs.clear();
    _tts.stop();
    _liveSession.disconnect();
    _setStateIfMounted(AssistantState.inactive);
  }

  void _setStateIfMounted(AssistantState s) {
    if (mounted) setState(() => _state = s);
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _amplitudeSub?.cancel();
    _proactiveTimer?.cancel();
    for (final sub in _subs) { sub.cancel(); }
    _liveSession.disconnect();
    _liveSession.dispose();
    _tts.dispose();
    _audio.dispose();
    _cameraCtrl?.dispose();
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    super.dispose();
  }

  // ─── BUILD ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isActive = _state != AssistantState.inactive;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Imagen: último frame capturado o preview en vivo si aún no hay ninguno ──
          if (_lastFrameBytes != null)
            _FrameDisplay(bytes: _lastFrameBytes!)
          else if (_cameraCtrl != null && _cameraCtrl!.value.isInitialized)
            _CameraFullscreen(controller: _cameraCtrl!)
          else
            const Center(child: CircularProgressIndicator()),

          // ── Overlay degradado inferior ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).size.height * 0.55,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xD9000000)],
                ),
              ),
            ),
          ),

          // ── Botón volumen ──
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            right: 16,
            child: _CircleButton(
              icon: _tts.isEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              onTap: () => setState(() => _tts.toggle()),
            ),
          ),

          // ── Contenido inferior ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: _buildBottomContent(colors, isActive),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomContent(ColorScheme colors, bool isActive) {
    final showStreaming = _state == AssistantState.processing ||
        (_state == AssistantState.speaking && _geminiText.isNotEmpty);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Transcripción del usuario
        if (_transcription.isNotEmpty) ...[
          _SpeechBubble(
            text: _transcription,
            isUser: true,
            colors: colors,
          ),
          const SizedBox(height: 10),
        ],

        // Respuesta de Gemini
        if (_geminiText.isNotEmpty) ...[
          _SpeechBubble(
            text: _geminiText,
            isUser: false,
            colors: colors,
            isStreaming: showStreaming,
          ),
          const SizedBox(height: 20),
        ],

        // Slider de intervalo proactivo
        _IntervalSlider(
          value: _proactiveIntervalSec,
          onChanged: (v) {
            setState(() => _proactiveIntervalSec = v);
            if (_state == AssistantState.listening) _startProactiveTimer();
          },
        ),
        const SizedBox(height: 12),

        // Indicador de estado animado
        _StateIndicator(
          state: _state,
          pulseAnim: _pulseAnim,
          waveAnim: _waveAnim,
          colors: colors,
        ),
        const SizedBox(height: 20),

        // Botón principal
        _MainButton(
          isActive: isActive,
          onTap: isActive ? _stopSession : _startSession,
          colors: colors,
        ),
      ],
    );
  }
}

// ─── Widget: último frame capturado (lo que Gemini "ve") ──────────────────────

class _FrameDisplay extends StatelessWidget {
  final Uint8List bytes;
  const _FrameDisplay({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );
  }
}

// ─── Widget: cámara a pantalla completa ───────────────────────────────────────

class _CameraFullscreen extends StatelessWidget {
  final CameraController controller;
  const _CameraFullscreen({required this.controller});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final camRatio = controller.value.aspectRatio;
    final screenRatio = size.width / size.height;
    final scale = camRatio < screenRatio
        ? size.width / (size.height * camRatio)
        : size.height * camRatio / size.width;

    return Transform.scale(
      scale: scale,
      child: Center(child: CameraPreview(controller)),
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

// ─── Widget: indicador de estado ───────────────────────────────────────────────

class _StateIndicator extends StatelessWidget {
  final AssistantState state;
  final Animation<double> pulseAnim;
  final Animation<double> waveAnim;
  final ColorScheme colors;

  const _StateIndicator({
    required this.state,
    required this.pulseAnim,
    required this.waveAnim,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      AssistantState.inactive   => const SizedBox.shrink(),
      AssistantState.listening  => _ListeningWave(anim: pulseAnim),
      AssistantState.recording  => _RecordingIndicator(anim: pulseAnim, colors: colors),
      AssistantState.processing => const _ProcessingSpinner(),
      AssistantState.speaking   => _SpeakingWave(anim: waveAnim, colors: colors),
    };
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
          Text('Escuchando…', style: TextStyle(color: Colors.white54, fontSize: 13)),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mic_rounded, color: colors.error, size: 40),
          const SizedBox(height: 6),
          Text(
            'Grabando…',
            style: TextStyle(color: colors.error, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _ProcessingSpinner extends StatelessWidget {
  const _ProcessingSpinner();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2.5),
        ),
        SizedBox(height: 8),
        Text('Pensando…', style: TextStyle(color: Colors.white54, fontSize: 13)),
      ],
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
                color: colors.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
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
          backgroundColor: isActive ? colors.errorContainer : colors.primaryContainer,
          foregroundColor: isActive ? colors.onErrorContainer : colors.onPrimaryContainer,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        icon: Icon(isActive ? Icons.stop_rounded : Icons.spatial_audio_off_rounded, size: 22),
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
                divisions: 9,  // 3, 6, 9, 12, 15, 18, 21, 24, 27, 30
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
