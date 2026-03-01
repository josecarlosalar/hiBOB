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
