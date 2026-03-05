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
import { AiService, GeminiLiveSession } from '../ai/ai.service';

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

  constructor(private readonly aiService: AiService) { }

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

      // Iniciar sesión Live con Gemini para este cliente
      const session = await this.aiService.createLiveSession({
        systemInstruction: 'Eres hiBOB, un asistente multimodal para personas con discapacidad visual. Responde de forma concisa (máximo 3 frases) y natural. Tienes ojos (la cámara) y oídos (el micrófono).',
      });

      client.data.geminiSession = session;

      // Escuchar eventos de Gemini y retransmitir al cliente
      session.on('text', (text) => {
        this.logger.log(`Gemini -> Cliente [chunk]: ${text.length} chars`);
        client.emit('chunk', { text });
      });
      session.on('audio', (base64Audio) => {
        this.logger.log(`Gemini -> Cliente [audio_chunk]: ${base64Audio.length} bytes`);
        client.emit('audio_chunk', { data: base64Audio });
      });
      session.on('done', () => {
        this.logger.log('Gemini -> Cliente [done]');
        client.emit('done', {});
      });
      session.on('interruption', () => {
        this.logger.log('Gemini -> Cliente [interruption]');
        client.emit('interruption', {});
      });

      session.on('tool_call', async (toolCall) => {
        this.logger.log(`Gemini -> Tool Call: ${JSON.stringify(toolCall)}`);
        const results = await Promise.all(
          toolCall.functionCalls.map(async (fc: any) => {
            const result = await (this.aiService as any).executeTool(fc.name, fc.args);

            // Si es un comando de hardware, notificar al móvil
            if (fc.name === 'toggle_flashlight') {
              client.emit('command', { action: 'flashlight', enabled: fc.args.enabled });
            } else if (fc.name === 'trigger_haptic_feedback') {
              client.emit('command', { action: 'vibrate', pattern: fc.args.pattern });
            }

            return {
              name: fc.name,
              id: fc.id,
              response: { content: result },
            };
          }),
        );
        this.logger.log(`Tool Response -> Gemini: ${JSON.stringify(results)}`);
        session.sendToolResponse(results);
      });

      session.on('error', (err) => {
        this.logger.error(`Gemini Error: ${err.message}`);
        client.emit('error', { message: err.message });
      });

    } catch (err) {
      this.logger.error(`Error al conectar con Gemini Live API para cliente ${client.id}: ${err.message}`, err.stack);
      client.emit('error', { message: 'No se pudo conectar con el asistente de IA' });
      client.disconnect();
    }
  }

  handleDisconnect(client: Socket) {
    this.logger.log(`Cliente desconectado: ${client.id}`);
    const session = client.data.geminiSession as GeminiLiveSession;
    session?.close();
  }

  @SubscribeMessage('voice_frame')
  async handleVoiceFrame(
    @MessageBody() payload: VoiceFramePayload,
    @ConnectedSocket() client: Socket,
  ) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (!session) return;

    try {
      this.logger.log(`Cliente -> Gemini [voice_frame]: audio=${payload.audioBase64?.length || 0} bytes, frame=${payload.frameBase64?.length || 0} bytes`);
      if (payload.audioBase64) {
        session.sendAudioFrame(payload.audioBase64);
      }
      if (payload.frameBase64) {
        session.sendFrameWithPrompt(payload.frameBase64);
      }
    } catch (err) {
      this.logger.error(`Error enviando a Gemini (voice_frame): ${err.message}`);
    }
  }

  @SubscribeMessage('frame')
  async handleFrame(
    @MessageBody() payload: FramePayload,
    @ConnectedSocket() client: Socket,
  ) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (!session) return;

    try {
      if (payload.frameBase64) {
        this.logger.log(`Cliente -> Gemini [frame]: prompt="${payload.prompt || ''}", frame=${payload.frameBase64.length} bytes`);
        session.sendFrameWithPrompt(payload.frameBase64, payload.prompt);
      }
    } catch (err) {
      this.logger.error(`Error enviando frame a Gemini (frame): ${err.message}`);
    }
  }
}
