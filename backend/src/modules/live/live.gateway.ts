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
import { LocationService } from '../tools/location.service';

interface FramePayload {
  conversationId: string;
  frameBase64: string;
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

  constructor(
    private readonly aiService: AiService,
    private readonly locationService: LocationService,
  ) {}

  async handleConnection(client: Socket) {
    const token = client.handshake.auth?.token as string | undefined;
    const host = client.handshake.headers?.host ?? 'unknown-host';
    const origin = client.handshake.headers?.origin ?? 'unknown-origin';
    this.logger.log(
      `Handshake recibido: client=${client.id}, nsp=${client.nsp.name}, host=${host}, origin=${origin}, tokenPresent=${token != null}, tokenLen=${token?.length ?? 0}`,
    );

    if (!token) {
      this.logger.warn(`Cliente ${client.id} sin token - desconectando`);
      client.emit('error', { message: 'Falta token de autenticacion en handshake.' });
      client.disconnect();
      return;
    }

    try {
      const decoded = await admin.auth().verifyIdToken(token);
      client.data.uid = decoded.uid;
      this.logger.log(`Cliente conectado: ${client.id} (uid=${decoded.uid})`);
      this.logger.log(`Creando sesion Gemini Live para client=${client.id}`);

      const session = await this.aiService.createLiveSession({
        systemInstruction:
          'Eres hiBOB, un asistente multimodal para personas con discapacidad visual. Responde de forma concisa (maximo 3 frases) y natural. Tienes ojos (la camara) y oidos (el microfono).',
      });

      client.data.geminiSession = session;
      this.logger.log(`Sesion Gemini Live lista para client=${client.id}`);

      session.on('text', (text) => {
        this.logger.log(`Gemini -> Cliente [chunk]: ${text.length} chars`);
        client.emit('chunk', { text });
      });

      session.on('audio', (audio) => {
        const base64Audio = audio?.data as string | undefined;
        const mimeType = (audio?.mimeType as string | undefined) ?? 'audio/pcm';
        if (!base64Audio) return;
        this.logger.log(
          `Gemini -> Cliente [audio_chunk]: ${base64Audio.length} bytes, mimeType=${mimeType}`,
        );
        client.emit('audio_chunk', { data: base64Audio, mimeType });
      });

      session.on('transcription', (text) => {
        this.logger.log(`Gemini -> Cliente [transcription]: ${text.length} chars`);
        client.emit('transcription', { text });
      });

      session.on('done', () => {
        this.logger.log('Gemini -> Cliente [done]');
        client.emit('done', {});
      });

      session.on('interruption', () => {
        this.logger.log('Gemini -> Cliente [interruption]');
        client.emit('interruption', {});
      });

      session.on('close', (reason?: string) => {
        const message = reason ?? 'La sesion Live con Gemini se cerro inesperadamente.';
        this.logger.warn(`Gemini -> Cliente [close]: ${message}`);
        client.emit('error', { message });
      });

      session.on('tool_call', async (toolCall) => {
        this.logger.log(`Gemini -> Tool Call: ${JSON.stringify(toolCall)}`);
        const results = await Promise.all(
          toolCall.functionCalls.map(async (fc: any) => {
            const result = await (this.aiService as any).executeTool(fc.name, fc.args, client.id);

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
        const message = err?.message || 'Error desconocido en sesion Live';
        this.logger.error(`Gemini Error: ${message}`);
        client.emit('error', { message });
      });
    } catch (err) {
      const message = err?.message || String(err);
      this.logger.error(
        `Error al conectar con Gemini Live API para cliente ${client.id}: ${message}`,
        err?.stack,
      );
      client.emit('error', { message: 'No se pudo conectar con el asistente de IA' });
      client.disconnect();
    }
  }

  handleDisconnect(client: Socket) {
    this.logger.log(`Cliente desconectado: ${client.id}`);
    const session = client.data.geminiSession as GeminiLiveSession;
    session?.close();
    this.locationService.removeClientLocation(client.id);
  }

  @SubscribeMessage('update_location')
  handleUpdateLocation(
    @MessageBody() payload: { latitude: number; longitude: number; accuracy?: number },
    @ConnectedSocket() client: Socket,
  ) {
    if (payload?.latitude != null && payload?.longitude != null) {
      this.locationService.setClientLocation(client.id, {
        latitude: payload.latitude,
        longitude: payload.longitude,
        accuracy: payload.accuracy,
      });
      this.logger.log(
        `GPS actualizado para ${client.id}: lat=${payload.latitude}, lon=${payload.longitude}`,
      );
    }
  }

  @SubscribeMessage('voice_frame')
  async handleVoiceFrame(
    @MessageBody() payload: VoiceFramePayload,
    @ConnectedSocket() client: Socket,
  ) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (!session) return;
    if (session.isClosed()) {
      const message =
        session.getLastErrorMessage() ?? 'La sesion de IA no esta disponible. Intenta reconectar.';
      this.logger.warn(`voice_frame descartado: sesion cerrada para ${client.id}`);
      client.emit('error', { message });
      return;
    }

    try {
      this.logger.log(
        `Cliente -> Gemini [voice_frame]: audio=${payload.audioBase64?.length || 0} bytes, frame=${payload.frameBase64?.length || 0} bytes`,
      );
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
    if (session.isClosed()) {
      const message =
        session.getLastErrorMessage() ?? 'La sesion de IA no esta disponible. Intenta reconectar.';
      this.logger.warn(`frame descartado: sesion cerrada para ${client.id}`);
      client.emit('error', { message });
      return;
    }

    try {
      if (payload.frameBase64) {
        this.logger.log(
          `Cliente -> Gemini [frame]: frame=${payload.frameBase64.length} bytes`,
        );
        session.sendFrameWithPrompt(payload.frameBase64);
      }
    } catch (err) {
      this.logger.error(`Error enviando frame a Gemini (frame): ${err.message}`);
    }
  }
}
