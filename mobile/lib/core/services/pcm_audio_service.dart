import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class PcmAudioService {
  bool _isInitialized = false;
  bool _isPlaying = false;

  Future<void> init() async {
    if (_isInitialized) return;
    // Gemini Live devuelve PCM16 mono a 24kHz.
    await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
    await FlutterPcmSound.play();
    _isInitialized = true;
    _isPlaying = true;
  }

  /// Reproduce un chunk base64 PCM16 LE mono (24kHz).
  void feedBase64(String base64Audio, {String? mimeType}) {
    if (!_isInitialized) return;
    final normalizedMime = (mimeType ?? 'audio/pcm').toLowerCase();
    if (!normalizedMime.startsWith('audio/pcm')) {
      debugPrint('[PCM] Ignorando chunk no-PCM: mimeType=$mimeType');
      return;
    }
    try {
      final bytes = base64Decode(base64Audio);
      if (bytes.isEmpty) return;

      // PCM16 -> múltiplo de 2 bytes. Si llega impar, descartar último byte.
      final evenLength = bytes.length - (bytes.length % 2);
      if (evenLength <= 0) return;

      // Convertir bytes little-endian a Int16 explícitamente.
      final sampleCount = evenLength ~/ 2;
      final samples = Int16List(sampleCount);
      final data = ByteData.sublistView(bytes, 0, evenLength);
      for (var i = 0; i < sampleCount; i++) {
        samples[i] = data.getInt16(i * 2, Endian.little);
      }

      // El plugin requiere reproducción activa para vaciar la cola.
      if (!_isPlaying) {
        FlutterPcmSound.play();
        _isPlaying = true;
      }

      FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
    } catch (e) {
      debugPrint('[PCM] feedBase64 error: $e');
    }
  }

  void stop() {
    FlutterPcmSound.stop();
    _isPlaying = false;
  }

  void dispose() {
    FlutterPcmSound.stop();
    _isPlaying = false;
  }
}
