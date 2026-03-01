import { Injectable, Logger } from '@nestjs/common';
import * as admin from 'firebase-admin';
import { AiService } from '../ai/ai.service';
import { CreateMessageDto, MessageRole } from './dto/create-message.dto';
import { Content } from '@google-cloud/vertexai';

interface Message {
  role: string;
  text: string;
  timestamp: admin.firestore.Timestamp;
}

@Injectable()
export class ConversationService {
  private readonly logger = new Logger(ConversationService.name);
  private get db(): admin.firestore.Firestore {
    return admin.firestore();
  }

  constructor(private readonly aiService: AiService) {}

  async chat(dto: CreateMessageDto): Promise<{ text: string; conversationId: string }> {
    const { conversationId, text, imageBase64List } = dto;

    // Guardar mensaje del usuario
    await this.saveMessage(conversationId, MessageRole.USER, text);

    // Recuperar historial para contexto
    const history = await this.getHistory(conversationId);

    // Generar respuesta con Gemini
    const responseText = await this.aiService.generateContent(
      text,
      imageBase64List,
      history,
    );

    // Guardar respuesta del modelo
    await this.saveMessage(conversationId, MessageRole.MODEL, responseText);

    return { text: responseText, conversationId };
  }

  async getMessages(conversationId: string): Promise<Message[]> {
    const snapshot = await this.db
      .collection('conversations')
      .doc(conversationId)
      .collection('messages')
      .orderBy('timestamp', 'asc')
      .get();

    return snapshot.docs.map((doc) => doc.data() as Message);
  }

  private async saveMessage(
    conversationId: string,
    role: MessageRole,
    text: string,
  ): Promise<void> {
    await this.db
      .collection('conversations')
      .doc(conversationId)
      .collection('messages')
      .add({
        role,
        text,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
      });
  }

  private async getHistory(conversationId: string): Promise<Content[]> {
    const messages = await this.getMessages(conversationId);

    return messages.map((msg) => ({
      role: msg.role as 'user' | 'model',
      parts: [{ text: msg.text }],
    }));
  }
}
