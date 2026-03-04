import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class PcmAudioService {
  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;
    await FlutterPcmSound.setup(sampleRate: 16000, channelCount: 1);
    _isInitialized = true;
  }

  /// Reproduce un chunk de audio en base64 (LPCM 16-bit 16kHz).
  void feedBase64(String base64Audio) {
    if (!_isInitialized) return;
    final bytes = base64Decode(base64Audio);
    // Convertir Uint8List a Int16List (LPCM 16-bit)
    final int16List = Int16List.view(bytes.buffer);
    FlutterPcmSound.feed(PcmArrayInt16.fromList(int16List));
  }

  void stop() {
    FlutterPcmSound.stop();
  }

  void dispose() {
    FlutterPcmSound.stop();
  }
}
