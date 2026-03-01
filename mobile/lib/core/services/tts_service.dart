import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _enabled = true;

  TtsService() {
    _tts.setLanguage('es-ES');
    _tts.setSpeechRate(0.5);
    _tts.setVolume(1.0);
  }

  bool get isEnabled => _enabled;

  void toggle() => _enabled = !_enabled;

  Future<void> speak(String text) async {
    if (!_enabled || text.trim().isEmpty) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> stop() => _tts.stop();

  Future<void> dispose() => _tts.stop();
}
