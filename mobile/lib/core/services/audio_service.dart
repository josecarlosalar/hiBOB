import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class AudioService {
  final AudioRecorder _recorder = AudioRecorder();
  String? _currentPath;

  // Streaming continuo
  Timer? _chunkTimer;
  final _chunkController = StreamController<String>.broadcast();
  Stream<String> get audioChunkStream => _chunkController.stream;

  Future<bool> get hasPermission => _recorder.hasPermission();

  /// Stream de amplitud (dB) para VAD. Emite cada 80ms.
  Stream<Amplitude> amplitudeStream() {
    return _recorder.onAmplitudeChanged(const Duration(milliseconds: 80));
  }

  Future<void> startRecording() async {
    final dir = await getTemporaryDirectory();
    _currentPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.pcm';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: 16000,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
      path: _currentPath!,
    );
  }

  /// Inicia grabación continua enviando chunks PCM vía Stream.
  Future<void> startStreamingRecording({int intervalMs = 200}) async {
    _chunkTimer?.cancel();
    
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: 16000,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
    );

    stream.listen((data) {
      if (!_chunkController.isClosed) {
        _chunkController.add(base64Encode(data));
      }
    });
  }

  /// Detiene el streaming y devuelve el audio completo como base64.
  Future<String?> stopStreamingAndGetBase64() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    return stopAndGetBase64();
  }

  /// Detiene la grabación y retorna el audio como base64, o null si hubo error.
  Future<String?> stopAndGetBase64() async {
    final path = await _recorder.stop();
    if (path == null) return null;
    try {
      final bytes = await File(path).readAsBytes();
      return base64Encode(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<String?> stopRecording() => _recorder.stop();

  Future<bool> get isRecording => _recorder.isRecording();

  void dispose() {
    _chunkTimer?.cancel();
    _chunkController.close();
    _recorder.dispose();
  }
}
