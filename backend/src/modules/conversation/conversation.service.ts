import { ForbiddenException, Injectable, Logger } from '@nestjs/common';
import * as admin from 'firebase-admin';
import { AiService } from '../ai/ai.service';
import { CreateMessageDto, MessageRole } from './dto/create-message.dto';
import { Content } from '@google/genai';

interface Message {
  role: string;
  text: string;
  timestamp: admin.firestore.Timestamp;
}

interface ConversationSummary {
  id: string;
  createdAt: admin.firestore.Timestamp | null;
  updatedAt: admin.firestore.Timestamp | null;
}

@Injectable()
export class ConversationService {
  private readonly logger = new Logger(ConversationService.name);

  private get db(): admin.firestore.Firestore {
    return admin.firestore();
  }

  constructor(private readonly aiService: AiService) {}

  // ─── Validación de ownership ────────────────────────────────────────────

  private async assertOwnership(
    conversationId: string,
    uid: string,
  ): Promise<void> {
    const ref = this.db.collection('conversations').doc(conversationId);
    const snap = await ref.get();

    if (snap.exists) {
      const data = snap.data();
      if (data?.userId !== uid) {
        this.logger.warn(
          `User ${uid} attempted to access conversation ${conversationId} owned by ${data?.userId}`,
        );
        throw new ForbiddenException('No tienes acceso a esta conversación');
      }
    }
  }

  // ─── Upsert documento raíz ───────────────────────────────────────────────

  private async ensureConversation(
    conversationId: string,
    uid: string,
  ): Promise<void> {
    const ref = this.db.collection('conversations').doc(conversationId);
    const snap = await ref.get();

    if (!snap.exists) {
      await ref.set({
        userId: uid,
        participantUids: [uid],
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else {
      const data = snap.data();
      if (data?.userId !== uid) {
        throw new ForbiddenException('No tienes acceso a esta conversación');
      }
      await ref.update({
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }

  // ─── Chat bloqueante ─────────────────────────────────────────────────────

  async chat(
    dto: CreateMessageDto,
    uid: string,
  ): Promise<{ text: string; conversationId: string }> {
    const { conversationId, text, imageBase64List } = dto;

    await this.ensureConversation(conversationId, uid);
    await this.saveMessage(conversationId, MessageRole.USER, text);

    const history = await this.getHistory(conversationId);
    const responseText = await this.aiService.generateContent(
      text,
      imageBase64List,
      history,
    );

    await this.saveMessage(conversationId, MessageRole.MODEL, responseText);
    return { text: responseText, conversationId };
  }

  // ─── Chat streaming ──────────────────────────────────────────────────────

  async chatStream(
    dto: CreateMessageDto,
    uid: string,
    onChunk: (text: string) => void,
  ): Promise<void> {
    const { conversationId, text, imageBase64List } = dto;

    await this.ensureConversation(conversationId, uid);
    await this.saveMessage(conversationId, MessageRole.USER, text);

    const history = await this.getHistory(conversationId);
    let fullResponse = '';

    await this.aiService.generateContentStream(
      text,
      (chunk) => {
        fullResponse += chunk;
        onChunk(chunk);
      },
      imageBase64List,
      history,
    );

    await this.saveMessage(conversationId, MessageRole.MODEL, fullResponse);
  }

  // ─── Voz ─────────────────────────────────────────────────────────────────

  async processVoice(
    conversationId: string,
    audioBase64: string,
    mimeType: string,
    uid: string,
  ): Promise<{ transcribedText: string; responseText: string; conversationId: string }> {
    await this.ensureConversation(conversationId, uid);

    const transcribedText = await this.aiService.processAudio(audioBase64, mimeType);
    await this.saveMessage(conversationId, MessageRole.USER, transcribedText);

    const history = await this.getHistory(conversationId);
    const responseText = await this.aiService.generateContent(
      transcribedText,
      undefined,
      history,
    );

    await this.saveMessage(conversationId, MessageRole.MODEL, responseText);
    return { transcribedText, responseText, conversationId };
  }

  // ─── Mensajes ────────────────────────────────────────────────────────────

  async getMessages(conversationId: string, uid?: string): Promise<Message[]> {
    if (uid) {
      await this.assertOwnership(conversationId, uid);
    }

    const snapshot = await this.db
      .collection('conversations')
      .doc(conversationId)
      .collection('messages')
      .orderBy('timestamp', 'asc')
      .get();

    return snapshot.docs.map((doc) => doc.data() as Message);
  }

  // ─── Listar conversaciones del usuario ───────────────────────────────────

  async listConversations(uid: string): Promise<ConversationSummary[]> {
    const snap = await this.db
      .collection('conversations')
      .where('userId', '==', uid)
      .orderBy('updatedAt', 'desc')
      .limit(20)
      .get();

    return snap.docs.map((d) => {
      const data = d.data();
      return {
        id: d.id,
        createdAt: (data.createdAt as admin.firestore.Timestamp) ?? null,
        updatedAt: (data.updatedAt as admin.firestore.Timestamp) ?? null,
      };
    });
  }

  // ─── Helpers privados ────────────────────────────────────────────────────

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
