class AgentResponse {
  final String text;
  final String conversationId;

  const AgentResponse({
    required this.text,
    required this.conversationId,
  });

  factory AgentResponse.fromJson(Map<String, dynamic> json) => AgentResponse(
        text: json['text'] as String,
        conversationId: json['conversationId'] as String,
      );
}
