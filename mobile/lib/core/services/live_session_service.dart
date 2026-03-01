import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;

enum LiveSessionState { disconnected, connecting, connected, error }

class LiveSessionService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:3000',
  );

  io.Socket? _socket;
  LiveSessionState _state = LiveSessionState.disconnected;

  final _chunkController = StreamController<String>.broadcast();
  final _doneController = StreamController<String>.broadcast();
  final _stateController =
      StreamController<LiveSessionState>.broadcast();

  Stream<String> get onChunk => _chunkController.stream;
  Stream<String> get onDone => _doneController.stream;
  Stream<LiveSessionState> get onStateChange => _stateController.stream;
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
      ..connect();
  }

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
  }
}
