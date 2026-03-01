import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/models/message.dart';
import '../../../core/providers/api_providers.dart';
import '../widgets/input_bar.dart';
import '../widgets/message_bubble.dart';

final _conversationIdProvider = Provider<String>((_) => const Uuid().v4());

final _messagesProvider =
    StateNotifierProvider<_MessagesNotifier, List<Message>>(
  (ref) => _MessagesNotifier(),
);

class _MessagesNotifier extends StateNotifier<List<Message>> {
  _MessagesNotifier() : super([]);

  void add(Message message) => state = [...state, message];
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scrollController = ScrollController();
  bool _isLoading = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    final conversationId = ref.read(_conversationIdProvider);
    final api = ref.read(apiServiceProvider);
    final notifier = ref.read(_messagesProvider.notifier);

    notifier.add(Message(
      id: const Uuid().v4(),
      role: MessageRole.user,
      text: text,
      timestamp: DateTime.now(),
    ));

    setState(() => _isLoading = true);
    _scrollToBottom();

    try {
      final response = await api.chat(
        conversationId: conversationId,
        text: text,
      );

      notifier.add(Message(
        id: const Uuid().v4(),
        role: MessageRole.model,
        text: response.text,
        timestamp: DateTime.now(),
      ));
    } catch (e) {
      notifier.add(Message(
        id: const Uuid().v4(),
        role: MessageRole.model,
        text: 'Error al conectar con el agente: $e',
        timestamp: DateTime.now(),
      ));
    } finally {
      if (mounted) setState(() => _isLoading = false);
      _scrollToBottom();
    }
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
    final messages = ref.watch(_messagesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemini Live Agent'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text(
                      'Empieza una conversación\ncon el agente',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (_, i) => MessageBubble(message: messages[i]),
                  ),
          ),
          InputBar(isLoading: _isLoading, onSend: _send),
        ],
      ),
    );
  }
}
