import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;

enum LiveSessionState { disconnected, connecting, connected, error }

class LiveSessionService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://hibob-backend-777378009998.europe-west1.run.app',
  );

  io.Socket? _socket;
  LiveSessionState _state = LiveSessionState.disconnected;

  final _chunkController = StreamController<String>.broadcast();
  final _doneController = StreamController<String>.broadcast();
  final _stateController = StreamController<LiveSessionState>.broadcast();
  final _transcriptionController = StreamController<String>.broadcast();
  final _audioChunkController = StreamController<String>.broadcast();
  final _interruptionController = StreamController<void>.broadcast();
  final _commandController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<String> get onChunk => _chunkController.stream;
  Stream<String> get onDone => _doneController.stream;
  Stream<LiveSessionState> get onStateChange => _stateController.stream;
  Stream<String> get onTranscription => _transcriptionController.stream;
  Stream<String> get onAudioChunk => _audioChunkController.stream;
  Stream<void> get onInterruption => _interruptionController.stream;
  Stream<Map<String, dynamic>> get onCommand => _commandController.stream;
  LiveSessionState get state => _state;

  Future<void> connect(String idToken) async {
    _setState(LiveSessionState.connecting);

    _socket = io.io(
      '$_baseUrl/live',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': idToken})
          .disableAutoConnect()
          .build(),
    );

    _socket!
      ..onConnect((_) => _setState(LiveSessionState.connected))
      ..onDisconnect((_) => _setState(LiveSessionState.disconnected))
      ..onConnectError((_) => _setState(LiveSessionState.error))
      ..on('chunk', (data) {
        final text = (data as Map<String, dynamic>)['text'] as String? ?? '';
        if (text.isNotEmpty) _chunkController.add(text);
      })
      ..on('done', (data) {
        final text = (data as Map<String, dynamic>)['text'] as String? ?? '';
        _doneController.add(text);
      })
      ..on('transcription', (data) {
        final text = (data as Map<String, dynamic>)['text'] as String? ?? '';
        if (text.isNotEmpty) _transcriptionController.add(text);
      })
      ..on('audio_chunk', (data) {
        final audio = (data as Map<String, dynamic>)['data'] as String? ?? '';
        if (audio.isNotEmpty) _audioChunkController.add(audio);
      })
      ..on('interruption', (_) {
        _interruptionController.add(null);
      })
      ..on('command', (data) {
        _commandController.add(Map<String, dynamic>.from(data as Map));
      })
      ..connect();
  }

  /// Envía un frame de vídeo con audio del usuario para modo conversacional.
  void sendVoiceFrame({
    required String conversationId,
    required String frameBase64,
    required String audioBase64,
    String mimeType = 'audio/m4a',
  }) {
    if (_state != LiveSessionState.connected) return;

    _socket?.emit('voice_frame', {
      'conversationId': conversationId,
      'frameBase64': frameBase64,
      'audioBase64': audioBase64,
      'mimeType': mimeType,
    });
  }

  /// Envía un frame de vídeo sin audio (modo exploración proactiva).
  void sendFrame({
    required String conversationId,
    required String frameBase64,
    String? prompt,
  }) {
    if (_state != LiveSessionState.connected) return;

    _socket?.emit('frame', {
      'conversationId': conversationId,
      'frameBase64': frameBase64,
      if (prompt != null && prompt.isNotEmpty) 'prompt': prompt,
    });
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
    _chunkController.close();
    _doneController.close();
    _stateController.close();
    _transcriptionController.close();
    _audioChunkController.close();
    _interruptionController.close();
    _commandController.close();
  }
}
