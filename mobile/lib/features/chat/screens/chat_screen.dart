import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/models/message.dart';
import '../../../core/providers/api_providers.dart';
import '../../../core/providers/firebase_providers.dart';
import '../../../core/services/tts_service.dart';
import '../widgets/input_bar.dart';
import '../widgets/message_bubble.dart';

// Cada instancia de ChatScreen puede recibir un conversationId existente.
// Si es null, se genera uno nuevo.
class ChatScreen extends ConsumerStatefulWidget {
  final String? conversationId;

  const ChatScreen({super.key, this.conversationId});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late final String _conversationId;
  final _messages = <Message>[];
  final _scrollController = ScrollController();
  final _ttsService = TtsService();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _conversationId = widget.conversationId ?? const Uuid().v4();
  }

  @override
  void dispose() {
    _ttsService.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ─── Streaming de texto ─────────────────────────────────────────────────

  Future<void> _send(String text) async {
    final api = ref.read(apiServiceProvider);

    _addMessage(MessageRole.user, text);
    setState(() => _isLoading = true);
    _scrollToBottom();

    final modelMsgId = const Uuid().v4();
    _addMessageWithId(modelMsgId, MessageRole.model, '');
    String fullResponse = '';

    try {
      await for (final chunk in api.chatStream(
        conversationId: _conversationId,
        text: text,
      )) {
        fullResponse += chunk;
        _appendToMessage(modelMsgId, chunk);
        _scrollToBottom();
      }
      await _ttsService.speak(fullResponse);
    } catch (e) {
      _setMessageText(modelMsgId, 'Error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── Voz ────────────────────────────────────────────────────────────────

  Future<void> _handleVoice(String filePath) async {
    final api = ref.read(apiServiceProvider);

    setState(() => _isLoading = true);
    try {
      final result = await api.sendVoice(
        conversationId: _conversationId,
        audioFilePath: filePath,
      );

      final transcribed = result['transcribedText'] as String? ?? '';
      final response = result['responseText'] as String? ?? '';

      if (transcribed.isNotEmpty) _addMessage(MessageRole.user, transcribed);
      if (response.isNotEmpty) {
        _addMessage(MessageRole.model, response);
        await _ttsService.speak(response);
      }
      _scrollToBottom();
    } catch (e) {
      _addMessage(MessageRole.model, 'Error al procesar audio: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ─── Helpers de estado ───────────────────────────────────────────────────

  void _addMessage(MessageRole role, String text) {
    _addMessageWithId(const Uuid().v4(), role, text);
  }

  void _addMessageWithId(String id, MessageRole role, String text) {
    setState(() {
      _messages.add(Message(
        id: id,
        role: role,
        text: text,
        timestamp: DateTime.now(),
      ));
    });
  }

  void _appendToMessage(String id, String chunk) {
    setState(() {
      final idx = _messages.indexWhere((m) => m.id == id);
      if (idx == -1) return;
      final m = _messages[idx];
      _messages[idx] = Message(
        id: m.id,
        role: m.role,
        text: m.text + chunk,
        timestamp: m.timestamp,
      );
    });
  }

  void _setMessageText(String id, String text) {
    setState(() {
      final idx = _messages.indexWhere((m) => m.id == id);
      if (idx == -1) return;
      final m = _messages[idx];
      _messages[idx] = Message(
        id: m.id,
        role: m.role,
        text: text,
        timestamp: m.timestamp,
      );
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemini Live Agent'),
        centerTitle: true,
        actions: [
          StatefulBuilder(
            builder: (_, setState) => IconButton(
              icon: Icon(
                _ttsService.isEnabled ? Icons.volume_up : Icons.volume_off,
              ),
              tooltip: _ttsService.isEnabled ? 'Silenciar voz' : 'Activar voz',
              onPressed: () => setState(() => _ttsService.toggle()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Cerrar sesión',
            onPressed: () => ref.read(firebaseServiceProvider).signOut(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Empieza una conversación\ncon el agente',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) =>
                        MessageBubble(message: _messages[i]),
                  ),
          ),
          InputBar(
            isLoading: _isLoading,
            onSend: _send,
            onVoice: _handleVoice,
          ),
        ],
      ),
    );
  }
}
