import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

enum LiveSessionState { disconnected, connecting, connected, error }

class LiveSessionService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://hibob-backend-777378009998.europe-west1.run.app',
  );

  io.Socket? _socket;
  LiveSessionState _state = LiveSessionState.disconnected;

  final _stateController = StreamController<LiveSessionState>.broadcast();
  final _transcriptionController = StreamController<String>.broadcast();
  final _audioChunkController = StreamController<Map<String, String>>.broadcast();
  final _interruptionController = StreamController<void>.broadcast();
  final _doneController = StreamController<void>.broadcast();
  final _commandController = StreamController<Map<String, dynamic>>.broadcast();
  final _contentController = StreamController<Map<String, dynamic>>.broadcast();
  final _thinkingController = StreamController<Map<String, dynamic>?>.broadcast();
  final _frameRequestController = StreamController<Map<String, dynamic>>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  Stream<LiveSessionState> get onStateChange => _stateController.stream;
  Stream<String> get onTranscription => _transcriptionController.stream;
  Stream<Map<String, String>> get onAudioChunk => _audioChunkController.stream;
  Stream<void> get onInterruption => _interruptionController.stream;
  Stream<void> get onDone => _doneController.stream;
  Stream<Map<String, dynamic>> get onCommand => _commandController.stream;
  Stream<Map<String, dynamic>> get onDisplayContent => _contentController.stream;
  /// Notifica cuando el asistente está procesando una herramienta (ej. VirusTotal).
  Stream<Map<String, dynamic>?> get onThinkingState => _thinkingController.stream;
  /// El backend solicita un frame; el payload incluye `source` ('camera' o 'screen').
  Stream<Map<String, dynamic>> get onFrameRequest => _frameRequestController.stream;
  Stream<String> get onError => _errorController.stream;
  LiveSessionState get state => _state;

  Future<void> connect(String idToken) async {
    _setState(LiveSessionState.connecting);

    final authData = {'token': idToken};
    debugPrint('Connecting to WebSocket: $_baseUrl/live');

    _socket = io.io(
      '$_baseUrl/live',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth(authData)
          .setExtraHeaders({
            'Authorization': 'Bearer $idToken',
            'authorization': 'Bearer $idToken',
          })
          .enableReconnection()
          .setReconnectionAttempts(5)
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .disableAutoConnect()
          .build(),
    );

    _socket!
      ..onConnect((_) {
        debugPrint('WebSocket connected');
        _setState(LiveSessionState.connected);
      })
      ..onDisconnect((reason) {
        debugPrint('WebSocket disconnected: $reason');
        _setState(LiveSessionState.disconnected);
      })
      ..onConnectError((err) {
        debugPrint('WebSocket connect error: $err');
        _setState(LiveSessionState.error);
      })
      ..on('reconnect', (_) {
        debugPrint('WebSocket reconnected');
        _setState(LiveSessionState.connected);
      })
      ..on('reconnect_attempt', (attempt) {
        debugPrint('WebSocket reconnect attempt $attempt');
        _setState(LiveSessionState.connecting);
      })
      ..on('transcription', (data) {
        final text = (data as Map<String, dynamic>)['text'] as String? ?? '';
        if (text.isNotEmpty) _transcriptionController.add(text);
      })
      ..on('audio_chunk', (data) {
        final map = data as Map<String, dynamic>;
        final audio = map['data'] as String? ?? '';
        final mimeType = map['mimeType'] as String? ?? 'audio/pcm';
        if (audio.isNotEmpty) {
          _audioChunkController.add({
            'data': audio,
            'mimeType': mimeType,
          });
        }
      })
      ..on('interruption', (_) {
        _interruptionController.add(null);
      })
      ..on('done', (_) {
        _doneController.add(null);
      })
      ..on('frame_request', (data) {
        // El backend necesita un frame, con el campo source ('camera' o 'screen')
        final payload = (data is Map) ? Map<String, dynamic>.from(data) : <String, dynamic>{};
        _frameRequestController.add(payload);
      })
      ..on('command', (data) {
        _commandController.add(Map<String, dynamic>.from(data as Map));
      })
      ..on('display_content', (data) {
        _contentController.add(Map<String, dynamic>.from(data as Map));
      })
      ..on('thinking_state', (data) {
        _thinkingController.add(data == null ? null : Map<String, dynamic>.from(data as Map));
      })
      ..on('error', (data) {
        final message = (data as Map<String, dynamic>)['message'] as String? ?? 'Error desconocido';
        debugPrint('Backend Error: $message');
        _errorController.add(message);
      })
      ..connect();
  }

  /// Envía un chunk de audio PCM (base64) en modo streaming continuo.
  void sendAudioChunk({
    required String audioBase64,
    String mimeType = 'audio/pcm;rate=16000',
  }) {
    if (_state != LiveSessionState.connected) return;
    _socket?.emit('audio_chunk', {
      'audioBase64': audioBase64,
      'mimeType': mimeType,
    });
  }

  /// Notifica al servidor que el usuario ha comenzado a hablar (VAD Manual).
  void sendActivityStart() {
    if (_state != LiveSessionState.connected) return;
    debugPrint('[LiveSessionService] Sending activity_start');
    _socket?.emit('activity_start');
  }

  /// Notifica al servidor que el usuario ha terminado de hablar (VAD Manual).
  void sendActivityEnd() {
    if (_state != LiveSessionState.connected) return;
    debugPrint('[LiveSessionService] Sending activity_end');
    _socket?.emit('activity_end');
  }

  /// Envía un frame de cámara, imagen de galería o fichero arbitrario.
  void sendFrame({required String frameBase64, String? prompt, String? fileName}) {
    if (_state != LiveSessionState.connected) return;
    debugPrint('[LiveSessionService] Sending frame (${frameBase64.length} chars) prompt: $prompt fileName: $fileName');
    _socket?.emit('frame', {
      'frameBase64': frameBase64,
      if (prompt != null) 'prompt': prompt,
      if (fileName != null) 'fileName': fileName,
    });
  }

  /// Envía las coordenadas GPS del dispositivo al backend.
  void sendLocation({required double latitude, required double longitude, double? accuracy}) {
    if (_state != LiveSessionState.connected) return;
    _socket?.emit('update_location', {
      'latitude': latitude,
      'longitude': longitude,
      if (accuracy != null) 'accuracy': accuracy,
    });
  }

  /// Actualiza los ajustes persistentes del usuario (ej. voz).
  void updateSettings(Map<String, dynamic> settings) {
    if (_state != LiveSessionState.connected) return;
    debugPrint('[LiveSessionService] Updating settings: $settings');
    _socket?.emit('update_settings', settings);
  }

  void disconnect() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _setState(LiveSessionState.disconnected);
  }

  void _setState(LiveSessionState state) {
    _state = state;
    _stateController.add(state);
  }

  void dispose() {
    disconnect();
    _stateController.close();
    _transcriptionController.close();
    _audioChunkController.close();
    _interruptionController.close();
    _doneController.close();
    _commandController.close();
    _contentController.close();
    _frameRequestController.close();
    _errorController.close();
  }
}
