import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers/api_providers.dart';
import '../../chat/screens/chat_screen.dart';

final _conversationsProvider = FutureProvider.autoDispose<
    List<Map<String, dynamic>>>((ref) async {
  return ref.watch(apiServiceProvider).listConversations();
});

class ConversationsScreen extends ConsumerWidget {
  const ConversationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncConversations = ref.watch(_conversationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Historial'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(_conversationsProvider),
            tooltip: 'Actualizar',
          ),
        ],
      ),
      body: asyncConversations.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 48),
              const SizedBox(height: 12),
              Text('Error: $e', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.invalidate(_conversationsProvider),
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
        data: (conversations) {
          if (conversations.isEmpty) {
            return const Center(
              child: Text(
                'No hay conversaciones aún.\nEmpieza una en el tab Chat.',
                textAlign: TextAlign.center,
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: conversations.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final conv = conversations[index];
              final id = conv['id'] as String;
              final shortId = id.length > 8 ? id.substring(0, 8) : id;

              return ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.chat_bubble_rounded),
                ),
                title: Text('Conversación #${index + 1}'),
                subtitle: Text(shortId, style: const TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(conversationId: id),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
