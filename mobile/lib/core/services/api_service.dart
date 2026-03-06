import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/agent_response.dart';
import '../models/message.dart';
import 'firebase_service.dart';

class ApiService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://hibob-backend-777378009998.europe-west1.run.app',
  );

  final http.Client _client;
  final FirebaseService _firebaseService;

  ApiService({http.Client? client, required FirebaseService firebaseService})
      : _client = client ?? http.Client(),
        _firebaseService = firebaseService;

  Future<Map<String, String>> _authHeaders() async {
    final token = await _firebaseService.getIdToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // ─── Chat bloqueante ────────────────────────────────────────────────────

  Future<AgentResponse> chat({
    required String conversationId,
    required String text,
    List<String>? imageBase64List,
  }) async {
    final headers = await _authHeaders();
    final body = {
      'conversationId': conversationId,
      'role': 'user',
      'text': text,
      if (imageBase64List != null) 'imageBase64List': imageBase64List,
    };

    final response = await _client.post(
      Uri.parse('$_baseUrl/conversation/chat'),
      headers: headers,
      body: jsonEncode(body),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Error ${response.statusCode}: ${response.body}');
    }

    return AgentResponse.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  // ─── Chat streaming (SSE) ───────────────────────────────────────────────

  Stream<String> chatStream({
    required String conversationId,
    required String text,
    List<String>? imageBase64List,
  }) async* {
    final headers = await _authHeaders();
    final body = {
      'conversationId': conversationId,
      'role': 'user',
      'text': text,
      if (imageBase64List != null) 'imageBase64List': imageBase64List,
    };

    final request = http.Request(
      'POST',
      Uri.parse('$_baseUrl/conversation/chat/stream'),
    );
    request.headers.addAll(headers);
    request.body = jsonEncode(body);

    final streamedResponse = await _client.send(request);

    await for (final raw in streamedResponse.stream.transform(utf8.decoder)) {
      for (final line in raw.split('\n')) {
        if (!line.startsWith('data: ') || line.contains('[DONE]')) continue;
        final jsonStr = line.substring(6).trim();
        if (jsonStr.isEmpty) continue;
        try {
          final map = jsonDecode(jsonStr) as Map<String, dynamic>;
          final chunk = map['text'] as String?;
          if (chunk != null && chunk.isNotEmpty) yield chunk;
        } catch (_) {}
      }
    }
  }

  // ─── Voz ────────────────────────────────────────────────────────────────

  // Flujo REST legado (no usado en Live API): puede recibir audio/m4a.
  Future<Map<String, dynamic>> sendVoice({
    required String conversationId,
    required String audioFilePath,
    String mimeType = 'audio/m4a',
  }) async {
    final headers = await _authHeaders();
    final bytes = await File(audioFilePath).readAsBytes();
    final audioBase64 = base64Encode(bytes);

    final response = await _client.post(
      Uri.parse('$_baseUrl/conversation/voice'),
      headers: headers,
      body: jsonEncode({
        'conversationId': conversationId,
        'audioBase64': audioBase64,
        'mimeType': mimeType,
      }),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Error ${response.statusCode}: ${response.body}');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  // ─── Historial de mensajes ──────────────────────────────────────────────

  Future<List<Message>> getMessages(String conversationId) async {
    final headers = await _authHeaders();
    final response = await _client.get(
      Uri.parse('$_baseUrl/conversation/$conversationId/messages'),
      headers: headers,
    );

    if (response.statusCode != 200) {
      throw Exception('Error ${response.statusCode}: ${response.body}');
    }

    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ─── Listar conversaciones ──────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listConversations() async {
    final headers = await _authHeaders();
    final response = await _client.get(
      Uri.parse('$_baseUrl/conversation'),
      headers: headers,
    );

    if (response.statusCode != 200) {
      throw Exception('Error ${response.statusCode}: ${response.body}');
    }

    return (jsonDecode(response.body) as List<dynamic>)
        .cast<Map<String, dynamic>>();
  }

  // ─── Health check ───────────────────────────────────────────────────────

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
