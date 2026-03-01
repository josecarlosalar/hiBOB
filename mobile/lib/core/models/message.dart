enum MessageRole { user, model }

class Message {
  final String id;
  final MessageRole role;
  final String text;
  final DateTime timestamp;
  final List<String>? imageBase64List;

  const Message({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
    this.imageBase64List,
  });

  bool get isUser => role == MessageRole.user;

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String? ?? '',
        role: json['role'] == 'user' ? MessageRole.user : MessageRole.model,
        text: json['text'] as String,
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        'timestamp': timestamp.toIso8601String(),
        if (imageBase64List != null) 'imageBase64List': imageBase64List,
      };
}
