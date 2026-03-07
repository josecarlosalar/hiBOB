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

  /// Inicia grabación continua enviando chunks PCM cada [intervalMs] ms.
  /// Los chunks se emiten como base64 en [audioChunkStream].
  Future<void> startStreamingRecording({int intervalMs = 200}) async {
    _chunkTimer?.cancel();
    int lastOffset = 0;

    await startRecording();

    _chunkTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) async {
      final path = _currentPath;
      if (path == null) return;
      try {
        final file = File(path);
        if (!await file.exists()) return;
        final bytes = await file.readAsBytes();
        if (bytes.length <= lastOffset) return;
        final chunk = bytes.sublist(lastOffset);
        lastOffset = bytes.length;
        if (chunk.isNotEmpty && !_chunkController.isClosed) {
          _chunkController.add(base64Encode(chunk));
        }
      } catch (_) {}
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
