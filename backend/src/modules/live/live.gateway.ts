import {
  ConnectedSocket,
  MessageBody,
  OnGatewayConnection,
  OnGatewayDisconnect,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import * as admin from 'firebase-admin';
import { AiService } from '../ai/ai.service';

interface FramePayload {
  conversationId: string;
  frameBase64: string;
  prompt?: string;
}

interface VoiceFramePayload {
  conversationId: string;
  frameBase64: string;
  audioBase64: string;
  mimeType?: string;
}

@WebSocketGateway({
  cors: { origin: '*' },
  namespace: 'live',
})
export class LiveGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server: Server;

  private readonly logger = new Logger(LiveGateway.name);

  constructor(private readonly aiService: AiService) {}

  async handleConnection(client: Socket) {
    const token = client.handshake.auth?.token as string | undefined;

    if (!token) {
      this.logger.warn(`Cliente ${client.id} sin token — desconectando`);
      client.disconnect();
      return;
    }

    try {
      const decoded = await admin.auth().verifyIdToken(token);
      client.data.uid = decoded.uid;
      this.logger.log(`Cliente conectado: ${client.id} (uid=${decoded.uid})`);
    } catch {
      this.logger.warn(`Token inválido para cliente ${client.id}`);
      client.disconnect();
    }
  }

  handleDisconnect(client: Socket) {
    this.logger.log(`Cliente desconectado: ${client.id}`);
  }

  @SubscribeMessage('voice_frame')
  async handleVoiceFrame(
    @MessageBody() payload: VoiceFramePayload,
    @ConnectedSocket() client: Socket,
  ) {
    if (!client.data.uid) return;

    const mimeType = payload.mimeType ?? 'audio/m4a';

    try {
      // 1. Transcribir el audio del usuario
      const transcription = await this.aiService.processAudio(payload.audioBase64, mimeType);
      this.logger.log(`Transcripción (uid=${client.data.uid}): "${transcription}"`);

      // Emitir transcripción al cliente para mostrar en UI
      if (transcription.trim()) {
        client.emit('transcription', { text: transcription });
      }

      // 2. Construir prompt combinando voz + visión
      const prompt = transcription.trim()
        ? `El usuario ha dicho: "${transcription}"\n\nMirando la imagen de la cámara, responde de forma natural y concisa. Si la pregunta es sobre lo que ves, descríbelo. Habla directamente al usuario. Máximo 3 frases.`
        : 'Describe brevemente y de forma natural lo que ves en la imagen. Sé conciso, máximo 2 frases. Habla en primera persona como si fueras los ojos del usuario.';

      // 3. Generar respuesta con streaming (imagen + transcripción)
      let fullText = '';

      await this.aiService.generateContentStream(
        prompt,
        (chunk) => {
          fullText += chunk;
          client.emit('chunk', { text: chunk });
        },
        [payload.frameBase64],
      );

      client.emit('done', { text: fullText, conversationId: payload.conversationId });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.logger.error(`Error en voice_frame: ${message}`);
      client.emit('error', { message });
    }
  }

  @SubscribeMessage('frame')
  async handleFrame(
    @MessageBody() payload: FramePayload,
    @ConnectedSocket() client: Socket,
  ) {
    if (!client.data.uid) return;

    const prompt =
      payload.prompt?.trim() ||
      'Describe brevemente qué ves en la imagen. Sé conciso (máximo 2 frases).';

    try {
      let fullText = '';

      await this.aiService.generateContentStream(
        prompt,
        (chunk) => {
          fullText += chunk;
          client.emit('chunk', { text: chunk });
        },
        [payload.frameBase64],
      );

      client.emit('done', { text: fullText, conversationId: payload.conversationId });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      client.emit('error', { message });
    }
  }
}
