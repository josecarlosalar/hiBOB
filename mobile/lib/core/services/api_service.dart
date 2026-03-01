import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/agent_response.dart';
import '../models/message.dart';

class ApiService {
  // En desarrollo apunta a localhost; en producción usar la URL de Cloud Run
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:3000', // emulador Android → localhost
  );

  final http.Client _client;

  ApiService({http.Client? client}) : _client = client ?? http.Client();

  Future<AgentResponse> chat({
    required String conversationId,
    required String text,
    List<String>? imageBase64List,
  }) async {
    final body = {
      'conversationId': conversationId,
      'role': 'user',
      'text': text,
      if (imageBase64List != null) 'imageBase64List': imageBase64List,
    };

    final response = await _client.post(
      Uri.parse('$_baseUrl/conversation/chat'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Error ${response.statusCode}: ${response.body}');
    }

    return AgentResponse.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<List<Message>> getMessages(String conversationId) async {
    final response = await _client.get(
      Uri.parse('$_baseUrl/conversation/$conversationId/messages'),
    );

    if (response.statusCode != 200) {
      throw Exception('Error ${response.statusCode}: ${response.body}');
    }

    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> healthCheck() async {
    try {
      final response = await _client
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
