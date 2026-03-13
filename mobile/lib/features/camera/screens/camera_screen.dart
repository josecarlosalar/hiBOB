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
import 'package:file_picker/file_picker.dart';
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
  
  static const double _defaultVadThresholdDb = -40.0;
  static const double _defaultBargeInThresholdDb = -18.0;
  static const int _defaultSilenceMs = 650;
  static const int _defaultAgentSpeechGraceMs = 3000;

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
  String _voiceName = 'Puck';

  StreamSubscription<String>? _audioStreamSub;
  StreamSubscription<Amplitude>? _amplitudeSub;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _agentSpeechIdleTimer;
  DateTime? _bargeInStartedAt;
  DateTime? _agentSpeechStartedAt;
  DateTime? _agentSpeechEstimatedEndTime;
  bool _agentAudioActive = false;
  bool _isVibrating = false;
  // Post-playback hold-off: tiempo de silencio adicional tras el último chunk
  // de audio del agente para que el eco del altavoz decaiga antes de reanudar
  // el envío del micrófono a Gemini. Evita que el eco provoque falsas interrupciones.
  Timer? _echoHoldOffTimer;
  bool _inEchoHoldOff = false;
  bool _showCameraPreview = false;
  Timer? _hideCameraTimer;
  Map<String, dynamic>? _structuredContent;
  Map<String, dynamic>? _thinkingData;
  Map<String, dynamic>? _selectedItem;

  // Captura manual con cámara trasera
  bool _awaitingManualCapture = false;
  bool _openingGallery = false;
  Completer<String?>? _manualCaptureCompleter;
  Timer? _manualCaptureTimer;
  int _manualCaptureCountdown = 30;

  bool get _bargeInEnabled => _conversationProfile != 'Evitar cortes';
  
  // Para la nueva funcionalidad de galería / ficheros
  XFile? _selectedGalleryImage;
  PlatformFile? _selectedFile;

  late final AnimationController _pulseCtrl;
  late final AnimationController _waveCtrl;
  late final Animation<double> _pulseAnim;
  late final Animation<double> _waveAnim;
  late final AnimationController _bannerCtrl;
  double _micAmplitudeDb = -80.0;

  @override
  void initState() {
    super.initState();
    _initAnimations();
    _initCamera();
    unawaited(_loadConversationSettings());
    
    _liveSession.onDisplayContent.listen((data) {
      if (mounted) setState(() {
        _structuredContent = data;
        _thinkingData = null;
      });
    });

    _liveSession.onThinkingState.listen((data) {
      if (mounted) setState(() => _thinkingData = data);
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _waveCtrl.dispose();
    _bannerCtrl.dispose();
    _cameraCtrl?.dispose();
    _audio.dispose();
    _pcmAudio.dispose();
    _agentSpeechIdleTimer?.cancel();
    _echoHoldOffTimer?.cancel();
    _hideCameraTimer?.cancel();
    for (final sub in _subs) sub.cancel();
    super.dispose();
  }

  void _initAnimations() {
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _waveCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))..repeat(reverse: true);
    _bannerCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _pulseAnim = Tween<double>(begin: 0.88, end: 1.12).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _waveAnim = Tween<double>(begin: 0.3, end: 1.0).animate(CurvedAnimation(parent: _waveCtrl, curve: Curves.easeInOut));
  }

  Future<void> _initCamera() async {
    _availableCameras = await availableCameras();
    if (_availableCameras.isEmpty) return;
    final selectedCamera = _findCameraForLens(_selectedLensDirection) ?? _availableCameras.first;
    _selectedLensDirection = selectedCamera.lensDirection;
    _cameraCtrl = CameraController(selectedCamera, ResolutionPreset.medium, enableAudio: false);
    await _cameraCtrl!.initialize();
    if (mounted) setState(() {});
  }

  CameraDescription? _findCameraForLens(CameraLensDirection lensDirection) {
    for (final camera in _availableCameras) { if (camera.lensDirection == lensDirection) return camera; }
    return null;
  }

  Future<void> _switchCamera(CameraLensDirection lensDirection, {bool force = false}) async {
    if (!force && _selectedLensDirection == lensDirection && _cameraCtrl != null && _cameraCtrl!.value.isInitialized) return;
    final selectedCamera = _findCameraForLens(lensDirection);
    if (selectedCamera == null) return;
    
    // Dispose old one first to avoid 'Camera already in use' on some Androids
    await _cameraCtrl?.dispose();
    _cameraCtrl = null;
    if (mounted) setState(() {});

    final nextController = CameraController(selectedCamera, ResolutionPreset.medium, enableAudio: false);
    try {
      await nextController.initialize();
      _cameraCtrl = nextController;
      _selectedLensDirection = lensDirection;
      if (mounted) setState(() {});
    } catch (_) { await nextController.dispose(); }
  }

  /// Cambia a cámara trasera, espera a que produzca frames reales y luego
  /// muestra el preview. Así el usuario nunca ve la pantalla en negro.
  Future<void> _switchCameraForQr() async {
    // Forzamos reinicialización para asegurar que el stream de frames esté activo
    await _switchCamera(CameraLensDirection.back, force: true);
    
    // Pausa para que el hardware se asiente
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() {
      _showCameraPreview = true;
      _awaitingManualCapture = true;
      _manualCaptureCountdown = 30;
    });
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
          else if (s == LiveSessionState.disconnected) { 
            if (_state != AssistantState.inactive && !_openingGallery) {
              // En lugar de cerrar sesión, marcamos como reconectando para dar oportunidad a Socket.IO
              _setStateIfMounted(AssistantState.connecting);
            }
          }
        }),
        _liveSession.onAudioChunk.listen((audioChunk) {
          if (!mounted) return;
          final data = audioChunk['data'] as String? ?? '';
          if (data.isNotEmpty) {
            try {
              final bytesLength = (data.length * 3) ~/ 4 - (data.endsWith('==') ? 2 : (data.endsWith('=') ? 1 : 0));
              final sampleCount = bytesLength ~/ 2;
              final extraMillis = (sampleCount / 24000.0 * 1000).toInt();
              
              final now = DateTime.now();
              if (_agentSpeechEstimatedEndTime == null || now.isAfter(_agentSpeechEstimatedEndTime!)) {
                _agentSpeechEstimatedEndTime = now;
              }
              _agentSpeechEstimatedEndTime = _agentSpeechEstimatedEndTime!.add(Duration(milliseconds: extraMillis));
            } catch (_) {}
          }
          _markAgentSpeechActive();
          _setStateIfMounted(AssistantState.speaking);
          _pcmAudio.feedBase64(data, mimeType: audioChunk['mimeType']);
        }),
        _liveSession.onInterruption.listen((_) { if (mounted) _stopSpeaking(); }),
        _liveSession.onDone.listen((_) { if (mounted) _scheduleAgentSpeechEnd(); }),
        _liveSession.onFrameRequest.listen((data) async {
          if (!mounted) return;
          final source = data['source'] as String? ?? 'camera';
          if (source == 'manual_camera') {
            // Cambiar a cámara trasera y esperar a que esté lista antes de mostrar preview
            await _switchCameraForQr();
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
    unawaited(_audio.startStreamingRecording(intervalMs: 50));
    _amplitudeSub = _audio.amplitudeStream().listen(_handleAmplitudeSample);
    _audioStreamSub = _audio.audioChunkStream.listen((base64Chunk) {
      if (_liveSession.state == LiveSessionState.connected && _shouldForwardAudioChunk()) {
        _liveSession.sendAudioChunk(audioBase64: base64Chunk);
      }
    });
  }

  bool _shouldForwardAudioChunk() {
    // 1. Bloqueo por vibración (ruido de hardware)
    if (_isVibrating) return false;
    
    final now = DateTime.now();
    final isAudioHardwarePlaying = _agentSpeechEstimatedEndTime != null && now.isBefore(_agentSpeechEstimatedEndTime!);

    // 2. Hold-off post-playback: esperar a que el eco del altavoz decaiga
    //    antes de reanudar el envío del micrófono a Gemini.
    if (_inEchoHoldOff && !isAudioHardwarePlaying) return false;

    // 3. Si el agente está hablando, solo enviamos audio si supera el umbral de barge-in.
    // Esto permite que el usuario interrumpa pero evita que el propio eco del agente 
    // provoque una auto-interrupción accidental.
    final isAgentTalking = _agentAudioActive || _state == AssistantState.speaking || isAudioHardwarePlaying;

    if (isAgentTalking) {
      // Permitimos que pase el audio si supera el umbral de interrupción
      return _micAmplitudeDb >= _bargeInThresholdDb;
    }

    return true;
  }

  bool _manualActivitySignaled = false; // Evita enviar múltiples señales por el mismo turno de habla

  void _handleAmplitudeSample(Amplitude amp) {
    if (mounted) setState(() => _micAmplitudeDb = amp.current);
    if (_isVibrating) return;

    final now = DateTime.now();
    final isAudioHardwarePlaying = _agentSpeechEstimatedEndTime != null && now.isBefore(_agentSpeechEstimatedEndTime!);
    final isAgentTalking = _agentAudioActive || _state == AssistantState.speaking || isAudioHardwarePlaying;
    
    // Umbral dinámico de seguridad extrema contra eco.
    final threshold = isAgentTalking ? _bargeInThresholdDb : _vadThresholdDb;
    final requiredDurationMs = isAgentTalking ? 500 : 350;

    if (amp.current >= threshold) {
      _bargeInStartedAt ??= now;
      if (now.difference(_bargeInStartedAt!).inMilliseconds >= requiredDurationMs && _bargeInEnabled) {
        if (!_manualActivitySignaled) {
          debugPrint('[VAD] ActivityStart manual (> $threshold dB por ${requiredDurationMs}ms)');
          _liveSession.sendActivityStart();
          _manualActivitySignaled = true;
          if (!isAgentTalking) _setStateIfMounted(AssistantState.listening);
        }
      }
    } else {
      _bargeInStartedAt = null;
      // Si estábamos en medio de una actividad manual y el volumen baja, enviamos fin de actividad.
      // Usamos un margen (histeresis) para evitar ruidos pequeños cortando la frase.
      if (_manualActivitySignaled && amp.current < threshold - 15) {
        debugPrint('[VAD] ActivityEnd manual (< ${threshold - 15} dB)');
        _liveSession.sendActivityEnd();
        _manualActivitySignaled = false;
      }
    }
  }

  void _markAgentSpeechActive() {
    _agentSpeechStartedAt ??= DateTime.now();
    _agentAudioActive = true;
    
    // Al empezar a recibir audio del agente, nos aseguramos de que el hold-off 
    // esté desactivado para permitir interrupciones (barge-in).
    _echoHoldOffTimer?.cancel();
    _inEchoHoldOff = false;

    _scheduleAgentSpeechEnd(idleTimeoutMs: 2500);
  }

  void _scheduleAgentSpeechEnd({int idleTimeoutMs = 0}) {
    _agentSpeechIdleTimer?.cancel();
    
    final now = DateTime.now();
    int delayMs = idleTimeoutMs;
    
    if (_agentSpeechEstimatedEndTime != null && _agentSpeechEstimatedEndTime!.isAfter(now)) {
      final remainingMs = _agentSpeechEstimatedEndTime!.difference(now).inMilliseconds;
      if (remainingMs > delayMs) {
        delayMs = remainingMs;
      }
    }
    
    // Añadimos 200ms extra de padding de seguridad para asegurar que el buffer se vació.
    _agentSpeechIdleTimer = Timer(Duration(milliseconds: delayMs + 200), _handleAgentSpeechEnded);
  }

  void _handleAgentSpeechEnded() {
    _agentSpeechIdleTimer?.cancel();
    _agentAudioActive = false;
    if (_state != AssistantState.inactive) _setStateIfMounted(AssistantState.listening);
    
    // Activar hold-off SOLO al terminar de hablar para evitar que el eco final
    // residual del altavoz sea interpretado como una nueva interrupción.
    _echoHoldOffTimer?.cancel();
    _inEchoHoldOff = true;
    
    // Bajamos el hold-off a 600ms para ser más responsivos
    _echoHoldOffTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _inEchoHoldOff = false);
    });
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
      try {
        if (_cameraCtrl != null && _cameraCtrl!.value.isInitialized) {
          await _cameraCtrl!.setFlashMode(enabled ? FlashMode.torch : FlashMode.off);
          if (mounted) setState(() {});
        } else {
          if (enabled) await TorchLight.enableTorch(); else await TorchLight.disableTorch();
        }
      } catch (e) {
        debugPrint('Error toggle flashlight: $e');
      }
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
      final source = cmd['source'] as String?;
      if (source == 'gallery') {
        _openingGallery = true;
        _pickImageFromGallery();
      } else if (source == 'files') {
        _openingGallery = true;
        _pickAnyFile();
      } else {
        _openGalleryPicker();
      }
    }
  }

  Future<void> _openGalleryPicker() async {
    // Marcar como abriendo galería ANTES del diálogo para evitar que la desconexión
    // del WebSocket (al ir la app a background) cierre la sesión.
    _openingGallery = true;
    bool pickerChosen = false;
    try {
      await showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF111111),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('¿Qué quieres analizar?', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 20),
                ListTile(
                  leading: const Icon(Icons.image_outlined, color: Colors.white70),
                  title: const Text('Imagen de la galería', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('JPG, PNG, etc.', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  onTap: () { pickerChosen = true; Navigator.pop(ctx); _pickImageFromGallery(); },
                ),
                ListTile(
                  leading: const Icon(Icons.folder_open_outlined, color: Colors.white70),
                  title: const Text('Fichero del dispositivo', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('PDF, APK, ZIP, EXE…', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  onTap: () { pickerChosen = true; Navigator.pop(ctx); _pickAnyFile(); },
                ),
              ],
            ),
          ),
        ),
      );
    } catch (_) {}
    // Si el usuario cerró el bottom sheet sin elegir nada, restablecer la flag
    if (!pickerChosen) _openingGallery = false;
  }

  Future<void> _pickImageFromGallery() async {
    try {
      // Redimensionar a una resolución razonable para IA (máx 1600px)
      // Esto ahorra memoria RAM crítica y evita que el sistema cierre la app (OOM).
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (image != null) {
        setState(() => _selectedGalleryImage = image);
        _showImageReviewDialog();
      } else {
        _openingGallery = false;
      }
    } catch (e) {
      _openingGallery = false;
      _showMessage('Error abriendo galería: $e');
    }
  }

  Future<void> _pickAnyFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: false,
        withReadStream: false,
      );
      if (result != null && result.files.isNotEmpty) {
        setState(() => _selectedFile = result.files.first);
        _showFileReviewDialog();
      } else {
        _openingGallery = false;
      }
    } catch (e) {
      _openingGallery = false;
      _showMessage('Error abriendo gestor de ficheros: $e');
    }
  }

  void _showFileReviewDialog() {
    final file = _selectedFile!;
    final sizeKb = file.size / 1024;
    final sizeText = sizeKb >= 1024
        ? '${(sizeKb / 1024).toStringAsFixed(1)} MB'
        : '${sizeKb.toStringAsFixed(0)} KB';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Analizar fichero', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Icon(Icons.insert_drive_file_outlined, color: Colors.white54, size: 40),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(file.name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Text(sizeText, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () { _openingGallery = false; setState(() => _selectedFile = null); Navigator.pop(ctx); },
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24)),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () { _sendFileToAssistant(); Navigator.pop(ctx); },
                      style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
                      child: const Text('Analizar'),
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

  /// Garantiza que la sesión esté conectada. Si se desconectó mientras el usuario
  /// estaba en la galería/ficheros, reconecta completamente la sesión.
  Future<bool> _ensureConnected() async {
    if (_liveSession.state == LiveSessionState.connected) return true;

    // Intentar reconexión completa si la sesión se cayó durante la galería
    if (_state != AssistantState.inactive) {
      try {
        final token = await ref.read(firebaseServiceProvider).getIdToken();
        if (token == null) return false;
        _liveSession.disconnect();
        await Future.delayed(const Duration(milliseconds: 300));
        await _liveSession.connect(token);
      } catch (_) {
        return false;
      }
    }

    // Esperar hasta 8s a que conecte
    int retries = 16;
    while (_liveSession.state != LiveSessionState.connected && retries > 0) {
      await Future.delayed(const Duration(milliseconds: 500));
      retries--;
    }
    return _liveSession.state == LiveSessionState.connected;
  }

  Future<void> _sendFileToAssistant() async {
    if (_selectedFile == null) return;
    try {
      final file = _selectedFile!;
      if (file.path == null) { 
        _openingGallery = false;
        _showMessage('No se puede leer el fichero.'); 
        return; 
      }

      final bytes = await File(file.path!).readAsBytes();
      if (bytes.length > 32 * 1024 * 1024) {
        _openingGallery = false;
        _showMessage('El fichero supera el límite de 32 MB de VirusTotal.');
        setState(() => _selectedFile = null);
        return;
      }
      final fileBase64 = base64Encode(bytes);

      if (!await _ensureConnected()) {
        _showMessage('Sin conexión con hiBOB. Intenta de nuevo.');
        return;
      }

      _liveSession.sendFrame(frameBase64: fileBase64, fileName: file.name);
      
      // Mostrar overlay de progreso inmediatamente
      setState(() {
        _structuredContent = {
          'type': 'file_scan',
          'title': 'Analizando Fichero',
          'items': [{
            'id': 'scan_progress',
            'title': file.name,
            'description': 'Subiendo archivo a hiBOB...',
          }]
        };
        _selectedFile = null;
      });
      _openingGallery = false;
    } catch (e) {
      _openingGallery = false;
      _showMessage('Error enviando fichero: $e');
    }
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
                      onPressed: () { _openingGallery = false; setState(() => _selectedGalleryImage = null); Navigator.pop(context); },
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
      final imagePath = _selectedGalleryImage!.path;
      final bytes = await File(imagePath).readAsBytes();
      final frameBase64 = base64Encode(bytes);

      if (!await _ensureConnected()) {
        _showMessage('Sin conexión con hiBOB. Intenta de nuevo.');
        return;
      }

      _liveSession.sendFrame(frameBase64: frameBase64, prompt: 'analyze_image');

      // Mostrar overlay de progreso con la ruta local (no base64) para evitar destellos
      setState(() {
        _structuredContent = {
          'type': 'file_scan',
          'title': 'Analizando Imagen',
          'items': [{
            'id': 'scan_progress',
            'title': 'Imagen de Galería',
            'description': 'Enviando imagen a hiBOB...',
            'localPath': imagePath,
          }]
        };
        _selectedGalleryImage = null;
      });
      // Solo liberamos la flag de "galería" tras enviar con éxito
      _openingGallery = false;
    } catch (e) {
      _openingGallery = false;
      _showMessage('Error enviando imagen: $e');
    }
  }

  Future<String?> _captureFrame({String source = 'camera'}) async {
    try {
      if (source == 'gallery') {
        const double maxDim = 1600;
        final XFile? image = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: maxDim,
          maxHeight: maxDim,
          imageQuality: 85,
        );
        if (image == null) return null;
        final bytes = await File(image.path).readAsBytes();
        return base64Encode(bytes);
      }

      if (source == 'files') {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          withData: false,
          withReadStream: false,
        );
        if (result == null || result.files.isEmpty || result.files.first.path == null) return null;
        final bytes = await File(result.files.first.path!).readAsBytes();
        return base64Encode(bytes);
      }

      if (source == 'screen') {
        // La captura de pantalla en tiempo real requiere una librería adicional (device_screenshot).
        // Por ahora devolvemos null para evitar abrir la cámara por error si Gemini se equivoca de herramienta.
        debugPrint('[CameraScreen] Screen capture requested but not implemented. Use open_gallery for screenshots.');
        return null;
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

  void _stopSpeaking() {
    _pcmAudio.stop();
    _agentSpeechEstimatedEndTime = null;
    _echoHoldOffTimer?.cancel();
    _inEchoHoldOff = false;
    _handleAgentSpeechEnded();
  }

  void _stopSession() {
    _audioStreamSub?.cancel();
    _amplitudeSub?.cancel();
    _agentSpeechIdleTimer?.cancel();
    _echoHoldOffTimer?.cancel();
    _agentSpeechEstimatedEndTime = null;
    _inEchoHoldOff = false;
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
    if (newState == AssistantState.inactive) {
      _bannerCtrl.reverse();
    } else if (newState == AssistantState.listening || newState == AssistantState.speaking) {
      if (!_bannerCtrl.isAnimating && _bannerCtrl.value < 1.0) _bannerCtrl.forward();
    }
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
          // 1. Cámara de fondo (si está activa)
          _buildCameraPreview(size),
          // 2. Aura Gemini (solo si la cámara no está activa)
          if (!_showCameraPreview) _buildGeminiAura(colors),
          // 3. Banner copiloto activo
          _buildCopilotBanner(colors),
          // 4. Capa de contenido estructurado o esqueleto de carga
          if (_structuredContent != null || _thinkingData != null) _buildContentOverlay(size, colors),
          // 5. Interfaz de controles (siempre arriba)
          _buildTopOverlay(),
          _buildBottomControlBar(colors),
        ],
      ),
    );
  }

  Widget _buildGeminiAura(ColorScheme colors) {
    Color auraColor = _state == AssistantState.listening 
        ? colors.secondary.withValues(alpha: 0.3) 
        : (_state == AssistantState.speaking 
            ? Colors.cyanAccent.withValues(alpha: 0.38) 
            : colors.primary.withValues(alpha: 0.14));
            
    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: [auraColor, Colors.black87, Colors.black],
          center: Alignment.center,
          radius: 1.2,
        ),
      ),
      child: Center(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 800),
          opacity: _state == AssistantState.inactive ? 0.25 : 0.6,
          child: ShaderMask(
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colors.primary.withValues(alpha: 0.8),
                colors.secondary.withValues(alpha: 0.8),
              ],
            ).createShader(bounds),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // El Texto exacto del logo (sin el escudo)
                const Text(
                  'hiBOB',
                  style: TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: 6,
                  ),
                ),
                const Text(
                  'CYBERSECURITY AI',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCopilotBanner(ColorScheme colors) {
    if (_state == AssistantState.inactive) return const SizedBox.shrink();
    return Positioned(
      top: 100,
      left: 24,
      right: 24,
      child: FadeTransition(
        opacity: _bannerCtrl,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, -0.3), end: Offset.zero)
              .animate(CurvedAnimation(parent: _bannerCtrl, curve: Curves.easeOut)),
          child: _CopilotBanner(
            state: _state,
            amplitudeDb: _micAmplitudeDb,
            colors: colors,
          ),
        ),
      ),
    );
  }

  Widget _buildCameraPreview(Size size) {
    if (!_showCameraPreview) return const SizedBox.shrink();

    final ctrl = _cameraCtrl;
    final isReady = ctrl != null && ctrl.value.isInitialized;

    return Positioned.fill(
      child: Stack(
        children: [
          // Fondo negro
          Container(color: Colors.black),
          // Preview a pantalla completa corregido
          if (isReady)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: ctrl.value.previewSize?.height ?? size.width,
                  height: ctrl.value.previewSize?.width ?? size.height,
                  child: CameraPreview(ctrl),
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator(color: Colors.white54)),
          
          // Visor QR centrado
          if (_awaitingManualCapture)
            _QrViewfinderOverlay(size: size),

          // Botones de control inferiores (específicos de captura)
          if (_awaitingManualCapture)
            Positioned(
              left: 0, right: 0, bottom: 120, // Subido un poco para no chocar con la barra principal
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Text(
                          'Enfoca el QR y pulsa capturar · $_manualCaptureCountdown s',
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CircleButton(icon: Icons.close, onTap: _cancelManualCapture),
                      const SizedBox(width: 32),
                      // Botón de captura estilizado
                      GestureDetector(
                        onTap: _triggerManualCapture,
                        child: Container(
                          width: 84, height: 84,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white70, width: 4),
                          ),
                          child: Center(
                            child: Container(
                              width: 66, height: 66,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [Colors.white, Color(0xFFE0E0E0)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                boxShadow: [BoxShadow(color: Colors.white38, blurRadius: 12, spreadRadius: 1)],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 32),
                      _CircleButton(
                        icon: ctrl?.value.flashMode == FlashMode.torch ? Icons.flashlight_on_rounded : Icons.flashlight_off_rounded,
                        onTap: _toggleFlashLocally,
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTopOverlay() {
    return Positioned(top: 40, left: 20, right: 20, child: Row(children: [
      _StatusBadge(state: _state), 
      const Spacer(),
      _CircleButton(icon: Icons.tune_rounded, onTap: _openFineTuningPanel),
      const SizedBox(width: 10),
      _CircleButton(icon: Icons.logout_rounded, onTap: _signOut),
    ]));
  }

  Widget _buildBottomControlBar(ColorScheme colors) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 45,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(40),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(40),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                boxShadow: [
                  BoxShadow(
                    color: colors.primary.withValues(alpha: 0.1),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: IntrinsicWidth(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildAiActionButton(colors),
                    const SizedBox(width: 16),
                    _buildStateSpecificContent(colors),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAiActionButton(ColorScheme colors) {
    final isInactive = _state == AssistantState.inactive;
    final isConnecting = _state == AssistantState.connecting;
    final isSpeaking = _state == AssistantState.speaking || _agentAudioActive;
    
    return GestureDetector(
      onTap: () {
        if (isInactive) _startSession();
        else if (isSpeaking) _stopSpeaking(); // SI TOCA EL BOTÓN MIENTRAS HABLA, SE CALLA
        else _stopSession();
      },
      child: ScaleTransition(
        scale: isInactive ? const AlwaysStoppedAnimation(1.0) : _pulseAnim,
        child: Container(
          width: 54, height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle, 
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isConnecting 
                ? [Colors.grey[800]!, Colors.grey[700]!] 
                : [colors.primary, colors.secondary],
            ),
            boxShadow: [
              BoxShadow(
                color: (isConnecting ? Colors.black : (isSpeaking ? Colors.cyanAccent : colors.primary)).withValues(alpha: 0.4),
                blurRadius: 15,
                spreadRadius: 2,
              )
            ],
          ),
          child: Center(
            child: isConnecting 
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70))
              : Icon(isInactive ? Icons.auto_awesome_rounded : (isSpeaking ? Icons.close : Icons.stop_rounded), color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }

  Widget _buildStateSpecificContent(ColorScheme colors) {
    if (_state == AssistantState.inactive) {
      return const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('hiBOB AI', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
          Text('Pulsa para activar', style: TextStyle(color: Colors.white38, fontSize: 10)),
        ],
      );
    }
    
    if (_state == AssistantState.connecting) {
      return const Text('Iniciando...', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500));
    }
    
    if (_state == AssistantState.listening) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Escuchando', style: TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          ScaleTransition(scale: _pulseAnim, child: const Icon(Icons.mic_none_rounded, color: Colors.cyanAccent, size: 18)),
        ],
      );
    }
    
    if (_state == AssistantState.speaking) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('hiBOB hablando', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          _SpeakingWave(anim: _waveAnim, colors: colors),
        ],
      );
    }
    
    return const SizedBox.shrink();
  }

  Widget _buildContentOverlay(Size size, ColorScheme colors) {
    if (_structuredContent == null && _thinkingData != null) {
      return _ThinkingSkeletonOverlay(
        message: _thinkingData!['message'] as String? ?? 'Consultando base de datos...',
      );
    }
    
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
    if (type == 'features_slider') {
      return _FeaturesSliderOverlay(
        title: _structuredContent!['title'] as String? ?? 'Capacidades',
        items: _structuredContent!['items'] as List<dynamic>? ?? [],
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
      _vadThresholdDb = -35; 
      _bargeInThresholdDb = -12;
      _agentSpeechGraceMs = 2500;
    } else if (profile == 'Interrupcion facil') { 
      _vadThresholdDb = -45; 
      _bargeInThresholdDb = -25;
      _agentSpeechGraceMs = 800;
    } else { 
      _vadThresholdDb = -40; 
      _bargeInThresholdDb = -18;
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
            _SettingSlider(label: 'Sensibilidad VAD', valueLabel: '${_vadThresholdDb.toInt()} dB', value: _vadThresholdDb, min: -80, max: 0, divisions: 80, onChanged: (v) => updateSettings(() => _vadThresholdDb = v)),
            _SettingSlider(label: 'Umbral Interrupción', valueLabel: '${_bargeInThresholdDb.toInt()} dB', value: _bargeInThresholdDb, min: -50, max: 0, divisions: 50, onChanged: (v) => updateSettings(() => _bargeInThresholdDb = v)),
            const SizedBox(height: 24),
            const Align(alignment: Alignment.centerLeft, child: Text('Voz del Asistente', style: TextStyle(color: Colors.white, fontSize: 14))),
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _CalibrationChip(label: 'Puck (Clara)', isSelected: _voiceName == 'Puck', onTap: () => _updateVoice(updateSettings, 'Puck')),
                  const SizedBox(width: 8),
                  _CalibrationChip(label: 'Charon (Sabia)', isSelected: _voiceName == 'Charon', onTap: () => _updateVoice(updateSettings, 'Charon')),
                  const SizedBox(width: 8),
                  _CalibrationChip(label: 'Kore (Suave)', isSelected: _voiceName == 'Kore', onTap: () => _updateVoice(updateSettings, 'Kore')),
                  const SizedBox(width: 8),
                  _CalibrationChip(label: 'Fenrir (Seria)', isSelected: _voiceName == 'Fenrir', onTap: () => _updateVoice(updateSettings, 'Fenrir')),
                  const SizedBox(width: 8),
                  _CalibrationChip(label: 'Aoede (Fluida)', isSelected: _voiceName == 'Aoede', onTap: () => _updateVoice(updateSettings, 'Aoede')),
                ],
              ),
            ),
          ])));
        });
      },
    );
  }

  void _updateVoice(Function(VoidCallback) updateSettings, String voice) {
    updateSettings(() => _voiceName = voice);
    if (_liveSession.state == LiveSessionState.connected) {
      _liveSession.updateSettings({'voiceName': voice});
    }
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
        _voiceName = json['voiceName'] ?? 'Puck';
      });
    } catch (_) {}
  }
  Future<void> _persistConversationSettings() async {
    try { await (await _settingsFile()).writeAsString(jsonEncode({
      'conversationProfile': _conversationProfile, 
      'vadThresholdDb': _vadThresholdDb,
      'bargeInThresholdDb': _bargeInThresholdDb,
      'voiceName': _voiceName,
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
  int _stepIndex = 0;
  Timer? _stepTimer;

  static const _steps = [
    (Icons.cloud_upload_outlined, 'Enviando a hiBOB'),
    (Icons.fingerprint, 'Analizando contenido'),
    (Icons.analytics_outlined, 'Generando diagnóstico'),
  ];

  @override
  void initState() {
    super.initState();
    initSecurityAnims();
    _scanLineCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..repeat();
    // Avanzar pasos automáticamente: paso 1 a los 2s, paso 2 a los 5s
    _stepTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) { setState(() => _stepIndex = 1); }
      _stepTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _stepIndex = 2);
      });
    });
  }

  @override
  void didUpdateWidget(_ScanProgressOverlay old) {
    super.didUpdateWidget(old);
    // Si el backend actualiza la description, sincronizar el step visualmente
    final desc = _currentDescription();
    if (desc.contains('VirusTotal') || desc.contains('Analizando') || desc.contains('Subiendo a')) {
      if (_stepIndex < 1 && mounted) setState(() => _stepIndex = 1);
    }
    if (desc.contains('diagnos') || desc.contains('completado') || desc.contains('Veredicto')) {
      if (_stepIndex < 2 && mounted) setState(() => _stepIndex = 2);
    }
  }

  @override
  void dispose() {
    _stepTimer?.cancel();
    _scanLineCtrl.dispose();
    disposeSecurityAnims();
    super.dispose();
  }

  String _currentDescription() {
    final item = widget.items.isNotEmpty ? widget.items.first as Map<String, dynamic> : null;
    return item?['description'] as String? ?? 'Analizando...';
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF40C4FF);
    final item = widget.items.isNotEmpty ? widget.items.first as Map<String, dynamic> : null;
    final imgUrl = item?['imageUrl'] as String?;
    final localPath = item?['localPath'] as String?;
    final fileName = item?['title'] as String? ?? 'Archivo';
    final description = _currentDescription();

    return overlayShell(accent: accent, children: [
      overlayHeader(
        icon: Icons.security_rounded,
        badge: 'ESCÁNER DE SEGURIDAD',
        title: widget.title,
        accent: accent,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Container(
          width: double.infinity,
          height: 180,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (imgUrl != null || localPath != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(19),
                  child: localPath != null
                      ? Image.file(File(localPath), width: double.infinity, height: double.infinity, fit: BoxFit.cover)
                      : (imgUrl!.startsWith('data:')
                          ? Image.memory(base64Decode(imgUrl.split(',').last), width: double.infinity, height: double.infinity, fit: BoxFit.cover)
                          : Image.network(imgUrl, width: double.infinity, height: double.infinity, fit: BoxFit.cover)),
                )
              else
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.insert_drive_file_rounded, color: accent.withValues(alpha: 0.5), size: 64),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(fileName, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),

              // Capa de escaneo
              AnimatedBuilder(
                animation: _scanLineCtrl,
                builder: (_, __) => Positioned(
                  top: _scanLineCtrl.value * 180 - 2,
                  left: 0, right: 0,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.8), blurRadius: 10, spreadRadius: 2)],
                      gradient: LinearGradient(colors: [Colors.transparent, accent.withValues(alpha: 0.9), Colors.transparent]),
                    ),
                  ),
                ),
              ),

              // Esquinas
              ..._buildScanCorners(accent),
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.5, valueColor: AlwaysStoppedAnimation(accent.withValues(alpha: 0.8))),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        child: Text(
                          _steps[_stepIndex].$2,
                          key: ValueKey(_stepIndex),
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(description, style: const TextStyle(color: Colors.white38, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            for (int i = 0; i < _steps.length; i++)
              _buildProcessStep(_steps[i].$1, _steps[i].$2, i <= _stepIndex, i < _stepIndex),
          ],
        ),
      ),
      overlayCloseButton(widget.onClose),
    ]);
  }

  Widget _buildProcessStep(IconData icon, String label, bool active, bool done) {
    final color = active ? const Color(0xFF40C4FF) : Colors.white12;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(done ? Icons.check_circle_rounded : icon, size: 16, color: color),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: active ? Colors.white70 : Colors.white24, fontSize: 12)),
          const Spacer(),
          if (active && !done)
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, valueColor: AlwaysStoppedAnimation(color.withValues(alpha: 0.7)))),
          if (done)
            Icon(Icons.check_circle_rounded, size: 14, color: color),
        ],
      ),
    );
  }

  List<Widget> _buildScanCorners(Color accent) {
    const size = 24.0;
    const thick = 3.5;
    Widget corner(AlignmentGeometry align) => Positioned.fill(
      child: Align(alignment: align, child: Container(
        width: size, height: size,
        decoration: BoxDecoration(border: Border(
          top: (align == Alignment.topLeft || align == Alignment.topRight) ? BorderSide(color: accent, width: thick) : BorderSide.none,
          bottom: (align == Alignment.bottomLeft || align == Alignment.bottomRight) ? BorderSide(color: accent, width: thick) : BorderSide.none,
          left: (align == Alignment.topLeft || align == Alignment.bottomLeft) ? BorderSide(color: accent, width: thick) : BorderSide.none,
          right: (align == Alignment.topRight || align == Alignment.bottomRight) ? BorderSide(color: accent, width: thick) : BorderSide.none,
        )),
      )),
    );
    return [
      corner(Alignment.topLeft),
      corner(Alignment.topRight),
      corner(Alignment.bottomLeft),
      corner(Alignment.bottomRight),
    ];
  }
}

// ─── Banner Copiloto Activo ───────────────────────────────────────────────────

class _CopilotBanner extends StatelessWidget {
  final AssistantState state;
  final double amplitudeDb;
  final ColorScheme colors;

  const _CopilotBanner({
    required this.state,
    required this.amplitudeDb,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final isSpeaking = state == AssistantState.speaking;
    final accent = isSpeaking ? Colors.cyanAccent : colors.secondary;
    final label = isSpeaking ? 'hiBOB te habla…' : 'Copiloto activo — te escucho';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.45), width: 1.2),
        boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.18), blurRadius: 16)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Punto de estado pulsante
          _PulseDot(color: accent),
          const SizedBox(width: 10),
          // Texto
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.2),
            ),
          ),
          const SizedBox(width: 10),
          // VU-meter: 5 barras proporcionales a la amplitud
          _VuMeter(amplitudeDb: amplitudeDb, color: accent, active: state == AssistantState.listening),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: 8, height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: _anim.value),
          boxShadow: [BoxShadow(color: widget.color.withValues(alpha: _anim.value * 0.6), blurRadius: 6)],
        ),
      ),
    );
  }
}

class _VuMeter extends StatelessWidget {
  final double amplitudeDb;
  final Color color;
  final bool active;

  const _VuMeter({required this.amplitudeDb, required this.color, required this.active});

  @override
  Widget build(BuildContext context) {
    // Normaliza de [-80, -20] dB → [0.0, 1.0]
    final level = active ? ((amplitudeDb + 80) / 60).clamp(0.0, 1.0) : 0.0;
    const barCount = 5;
    const maxH = 18.0;
    const minH = 4.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: List.generate(barCount, (i) {
        final threshold = (i + 1) / barCount;
        final filled = level >= threshold;
        final barH = minH + (maxH - minH) * ((i + 1) / barCount);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1.5),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: 3,
            height: barH,
            decoration: BoxDecoration(
              color: filled ? color : Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Visor QR a pantalla completa: oscurece todo excepto el recuadro central
/// donde el usuario debe enfocar el código QR.
class _QrViewfinderOverlay extends StatelessWidget {
  final Size size;
  const _QrViewfinderOverlay({required this.size});

  @override
  Widget build(BuildContext context) {
    final boxSize = size.width * 0.65;
    final left = (size.width - boxSize) / 2;
    // Centrado visual: un poco más arriba para compensar la barra de controles inferior
    final top = (size.height - boxSize) / 2 - 40;

    return Positioned.fill(
      child: CustomPaint(
        painter: _QrDimPainter(
          cutoutRect: Rect.fromLTWH(left, top, boxSize, boxSize),
        ),
        child: Stack(
          children: [
            // Esquinas del visor
            ..._corners(left, top, boxSize),
            // Etiqueta
            Positioned(
              left: 0, right: 0,
              top: top + boxSize + 24,
              child: const Center(
                child: Text(
                  'Centra el código QR en el recuadro',
                  style: TextStyle(color: Colors.white, fontSize: 14,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black)]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _corners(double left, double top, double boxSize) {
    const arm = 24.0;
    const thick = 3.0;
    const r = 6.0;
    const color = Colors.white;

    Widget corner(double dx, double dy, bool mirrorX, bool mirrorY) {
      return Positioned(
        left: dx, top: dy,
        child: Transform.scale(
          scaleX: mirrorX ? -1 : 1,
          scaleY: mirrorY ? -1 : 1,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: arm, height: arm,
            child: CustomPaint(painter: _CornerPainter(color: color, thick: thick, r: r)),
          ),
        ),
      );
    }

    return [
      // Top Left: No mirroring, starts at (left, top)
      corner(left, top, false, false),
      // Top Right: Flipped on X. To end at (left+boxSize), must start at (left+boxSize)
      corner(left + boxSize, top, true, false),
      // Bottom Left: Flipped on Y. To end at (top+boxSize), must start at (top+boxSize)
      corner(left, top + boxSize, false, true),
      // Bottom Right: Flipped on X and Y.
      corner(left + boxSize, top + boxSize, true, true),
    ];
  }
}

class _QrDimPainter extends CustomPainter {
  final Rect cutoutRect;
  _QrDimPainter({required this.cutoutRect});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final full = Rect.fromLTWH(0, 0, size.width, size.height);
    final path = Path()
      ..addRect(full)
      ..addRRect(RRect.fromRectAndRadius(cutoutRect, const Radius.circular(12)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, paint);
    // Borde del recuadro
    canvas.drawRRect(
      RRect.fromRectAndRadius(cutoutRect, const Radius.circular(12)),
      Paint()..color = Colors.white54..style = PaintingStyle.stroke..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_QrDimPainter old) => old.cutoutRect != cutoutRect;
}

class _CornerPainter extends CustomPainter {
  final Color color;
  final double thick;
  final double r;
  const _CornerPainter({required this.color, required this.thick, required this.r});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thick
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, r)
      ..arcToPoint(Offset(r, 0), radius: Radius.circular(r))
      ..lineTo(size.width, 0);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CornerPainter old) => false;
}

// ─── Thinking Skeleton Overlay ──────────────────────────────────────────────

class _ThinkingSkeletonOverlay extends StatefulWidget {
  final String message;
  const _ThinkingSkeletonOverlay({required this.message});

  @override
  State<_ThinkingSkeletonOverlay> createState() => _ThinkingSkeletonOverlayState();
}

class _ThinkingSkeletonOverlayState extends State<_ThinkingSkeletonOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmerCtrl;
  late final Animation<double> _shimmerAnim;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
    _shimmerAnim = Tween<double>(begin: -1.0, end: 2.0).animate(CurvedAnimation(parent: _shimmerCtrl, curve: Curves.easeInOutSine));
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    const accent = Color(0xFF40C4FF);

    return Center(
      child: Container(
        width: size.width * 0.92,
        margin: const EdgeInsets.only(bottom: 50),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1.5),
          boxShadow: [const BoxShadow(color: Colors.black54, blurRadius: 40)],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header Skeleton
            _buildHeaderSkeleton(accent),
            // Body Skeleton
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  _buildShimmerBox(double.infinity, 45, radius: 12), // URL bar
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      _buildShimmerBox(88, 88, radius: 44), // Gauge
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          children: List.generate(3, (i) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _buildShimmerBox(double.infinity, 8, radius: 4),
                          )),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildShimmerBox(double.infinity, 60, radius: 14), // Engine breakdown
                  const SizedBox(height: 20),
                  Text(
                    widget.message.toUpperCase(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: accent.withValues(alpha: 0.7),
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderSkeleton(Color accent) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05))),
      ),
      child: Row(
        children: [
          _buildShimmerBox(52, 52, radius: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildShimmerBox(120, 8, radius: 4),
                const SizedBox(height: 8),
                _buildShimmerBox(180, 16, radius: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmerBox(double w, double h, {double radius = 8}) {
    return AnimatedBuilder(
      animation: _shimmerAnim,
      builder: (context, _) {
        return Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: [
                (_shimmerAnim.value - 0.4).clamp(0.0, 1.0),
                _shimmerAnim.value.clamp(0.0, 1.0),
                (_shimmerAnim.value + 0.4).clamp(0.0, 1.0),
              ],
              colors: [
                Colors.white.withValues(alpha: 0.05),
                Colors.white.withValues(alpha: 0.12),
                Colors.white.withValues(alpha: 0.05),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── Widgets de Contenido Premium ──────────────────────────────────────────

class _FeaturesSliderOverlay extends StatefulWidget {
  final String title;
  final List<dynamic> items;
  final VoidCallback onClose;

  const _FeaturesSliderOverlay({required this.title, required this.items, required this.onClose});

  @override
  State<_FeaturesSliderOverlay> createState() => _FeaturesSliderOverlayState();
}

class _FeaturesSliderOverlayState extends State<_FeaturesSliderOverlay> {
  final PageController _pageCtrl = PageController(viewportFraction: 0.85);
  int _currentPage = 0;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Título del Slider
          Text(
            widget.title.toUpperCase(),
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 2),
          ),
          const SizedBox(height: 24),
          
          // Carrusel de Capacidades
          SizedBox(
            height: 380,
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: widget.items.length,
              onPageChanged: (v) => setState(() => _currentPage = v),
              itemBuilder: (context, index) {
                final itemData = widget.items[index] as Map<String, dynamic>;
                final bool isCurrent = _currentPage == index;
                
                return AnimatedScale(
                  scale: isCurrent ? 1.0 : 0.9,
                  duration: const Duration(milliseconds: 300),
                  child: _FeatureItemCard(item: itemData, colors: colors),
                );
              },
            ),
          ),
          
          const SizedBox(height: 32),
          
          // Botón Cerrar Estilizado
          GestureDetector(
            onTap: widget.onClose,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.close, color: Colors.white70, size: 18),
                  SizedBox(width: 8),
                  Text('CERRAR', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 100), // Espacio para que no tape la barra inferior
        ],
      ),
    );
  }
}

class _FeatureItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final ColorScheme colors;

  const _FeatureItemCard({required this.item, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF121212).withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: colors.primary.withValues(alpha: 0.15),
            blurRadius: 30,
            spreadRadius: -10,
          )
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Stack(
          children: [
            // Fondo con gradiente sutil
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colors.primary.withValues(alpha: 0.05),
                      Colors.transparent,
                      colors.secondary.withValues(alpha: 0.05),
                    ],
                  ),
                ),
              ),
            ),
            
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Icono / ID visual
                  Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(_getIconForFeature(item['id']), color: colors.primary, size: 28),
                  ),
                  const Spacer(),
                  // Título
                  Text(
                    item['title'] as String? ?? 'Capacidad',
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, height: 1.1),
                  ),
                  const SizedBox(height: 12),
                  // Descripción
                  Text(
                    item['description'] as String? ?? '',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 15, height: 1.4),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIconForFeature(dynamic id) {
    final sId = id.toString().toLowerCase();
    if (sId.contains('virus') || sId.contains('scan')) return Icons.security;
    if (sId.contains('pass') || sId.contains('filtr')) return Icons.password;
    if (sId.contains('net') || sId.contains('red')) return Icons.lan;
    if (sId.contains('copilot') || sId.contains('guide')) return Icons.support_agent;
    if (sId.contains('camera') || sId.contains('vision')) return Icons.visibility;
    return Icons.star_outline;
  }
}
