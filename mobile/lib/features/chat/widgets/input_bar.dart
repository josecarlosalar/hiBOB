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

class _InputBarState extends State<InputBar>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _audioService = AudioService();
  bool _isRecording = false;
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..addStatusListener((s) {
        if (s == AnimationStatus.completed) _pulseCtrl.reverse();
        if (s == AnimationStatus.dismissed && _isRecording) _pulseCtrl.forward();
      });
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.35).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _controller.dispose();
    _audioService.dispose();
    super.dispose();
  }

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
      _pulseCtrl.stop();
      _pulseCtrl.reset();
      setState(() => _isRecording = false);
      if (path != null) widget.onVoice?.call(path);
    } else {
      final hasPermission = await _audioService.hasPermission;
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permiso de micrófono denegado')),
          );
        }
        return;
      }
      await _audioService.startRecording();
      setState(() => _isRecording = true);
      _pulseCtrl.forward();
    }
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
                enabled: !_isRecording && !widget.isLoading,
                decoration: InputDecoration(
                  hintText: _isRecording
                      ? 'Grabando…'
                      : widget.isLoading
                          ? 'El agente está respondiendo…'
                          : 'Escribe un mensaje…',
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
            // Botón micrófono con animación pulsante al grabar
            ScaleTransition(
              scale: _pulseAnim,
              child: IconButton(
                onPressed: widget.isLoading ? null : _toggleRecording,
                icon: Icon(
                  _isRecording
                      ? Icons.stop_circle_rounded
                      : Icons.mic_rounded,
                ),
                color: _isRecording ? colors.error : null,
                tooltip: _isRecording ? 'Detener grabación' : 'Grabar voz',
              ),
            ),
            const SizedBox(width: 2),
            // Botón enviar / indicador de carga
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
