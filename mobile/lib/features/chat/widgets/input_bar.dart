import 'package:flutter/material.dart';
import '../../../core/services/audio_service.dart';

class InputBar extends StatefulWidget {
  final bool isLoading;
  final void Function(String text) onSend;
  final void Function(String filePath)? onVoice;

  const InputBar({
    super.key,
    required this.onSend,
    this.onVoice,
    this.isLoading = false,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _controller = TextEditingController();
  final _audioService = AudioService();
  bool _isRecording = false;

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty || widget.isLoading) return;
    _controller.clear();
    widget.onSend(text);
  }

  Future<void> _toggleRecording() async {
    if (widget.isLoading) return;

    if (_isRecording) {
      final path = await _audioService.stopRecording();
      setState(() => _isRecording = false);
      if (path != null) widget.onVoice?.call(path);
    } else {
      final hasPermission = await _audioService.hasPermission;
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Permiso de micrófono denegado'),
            ),
          );
        }
        return;
      }
      await _audioService.startRecording();
      setState(() => _isRecording = true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _audioService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => _submit(),
                enabled: !_isRecording,
                decoration: InputDecoration(
                  hintText: _isRecording ? 'Grabando…' : 'Escribe un mensaje…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Botón micrófono
            IconButton(
              onPressed: widget.isLoading ? null : _toggleRecording,
              icon: Icon(
                _isRecording
                    ? Icons.stop_circle_rounded
                    : Icons.mic_rounded,
              ),
              color: _isRecording ? colors.error : null,
              tooltip: _isRecording ? 'Detener grabación' : 'Grabar voz',
            ),
            const SizedBox(width: 2),
            // Botón enviar
            widget.isLoading
                ? const SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton.filled(
                    onPressed: _isRecording ? null : _submit,
                    icon: const Icon(Icons.send_rounded),
                  ),
          ],
        ),
      ),
    );
  }
}
