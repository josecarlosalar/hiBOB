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

interface AudioChunkPayload {
  audioBase64: string;
  mimeType?: string;
}

interface FramePayload {
  frameBase64?: string;
  frame?: string;
  prompt?: string;
}

@WebSocketGateway({
  cors: { origin: '*' },
  namespace: 'live',
  pingInterval: 10000,
  pingTimeout: 5000,
})
export class LiveGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server: Server;

  private readonly logger = new Logger('LiveGateway-V2.6');

  constructor(
    private readonly aiService: AiService,
    private readonly locationService: LocationService,
  ) {}

  async handleConnection(client: Socket) {
    try {
      const token = client.handshake.auth?.token as string | undefined;
      if (!token) {
        this.logger.warn(`Cliente ${client.id} sin token - desconectando`);
        client.disconnect();
        return;
      }

      const decoded = await admin.auth().verifyIdToken(token);
      client.data.uid = decoded.uid;
      this.logger.log(`Cliente conectado: ${client.id} (uid=${decoded.uid})`);

      const session = await this.aiService.createLiveSession({
        systemInstruction:
          'Eres hiBOB, una asistente mujer multimodal de nueva generación. ' +
          'Responde siempre de forma breve y natural en español. ' +
          'Si el usuario te enseña su pantalla, analízala inmediatamente.',
      });

      client.data.geminiSession = session;

      // --- Monitor de Mensajes Salientes (Gemini -> Cliente) ---
      session.on('audio', (audio) => {
        if (!client.connected) return;
        client.emit('audio_chunk', { data: audio.data, mimeType: audio.mimeType || 'audio/pcm' });
      });

      session.on('transcription', (text) => {
        this.logger.log(`[Gemini] Transcripción: ${text}`);
        if (client.connected) client.emit('transcription', { text });
      });

      session.on('interruption', () => {
        this.logger.log(`[Gemini] Interrupción detectada`);
        if (client.connected) client.emit('interruption', {});
      });

      session.on('done', () => {
        if (client.connected) client.emit('done', {});
      });

      session.on('error', (err) => {
        this.logger.error(`[Gemini] Error: ${err.message}`);
        if (client.connected) client.emit('error', { message: err.message });
      });

      session.on('tool_call', async (toolCall) => {
        this.logger.log(`[Gemini] Tool Call: ${JSON.stringify(toolCall)}`);
        // (Lógica de tools mantenida igual que en V2.5 para brevedad...)
        const results = await Promise.all(
          toolCall.functionCalls.map(async (fc: any) => {
            if (fc.name === 'capture_device_screen' || fc.name === 'describe_camera_view') {
              client.emit('frame_request', { source: fc.name === 'capture_device_screen' ? 'screen' : 'camera' });
              const frame = await this._waitForFrame(client, 10000);
              if (!frame) return { name: fc.name, id: fc.id, response: { content: 'ERROR: No imagen' } };
              session.sendClientContent([{ inlineData: { data: frame, mimeType: 'image/jpeg' } }], false);
              return { name: fc.name, id: fc.id, response: { content: 'Imagen recibida' } };
            }
            const result = await (this.aiService as any).executeTool(fc.name, fc.args, client.id);
            return { name: fc.name, id: fc.id, response: { content: result } };
          }),
        );
        session.sendToolResponse(results);
      });

    } catch (err) {
      this.logger.error(`Error en conexión: ${err.message}`);
      client.disconnect();
    }
  }

  handleDisconnect(client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    session?.close();
    this.logger.log(`Cliente desconectado: ${client.id}`);
  }

  private _waitForFrame(client: Socket, timeoutMs: number): Promise<string | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve(null), timeoutMs);
      client.once('frame', (p: FramePayload) => {
        clearTimeout(timer);
        resolve(p?.frameBase64 || p?.frame || null);
      });
    });
  }

  @SubscribeMessage('audio_chunk')
  handleAudioChunk(@MessageBody() payload: AudioChunkPayload, @ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (session && !session.isClosed() && payload?.audioBase64) {
      // Log cada 20 paquetes para no inundar el log, pero confirmar que llega audio
      if (Math.random() < 0.05) this.logger.debug(`Recibiendo audio de ${client.id}...`);
      session.sendAudioFrame(payload.audioBase64, payload.mimeType || 'audio/pcm;rate=16000');
    }
  }

  @SubscribeMessage('frame')
  handleFrame(@MessageBody() payload: FramePayload, @ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    const frame = payload?.frameBase64 || payload?.frame;
    if (session && !session.isClosed() && frame) {
      this.logger.log(`[Visión] Frame proactivo de ${client.id}`);
      session.sendClientContent([{ inlineData: { data: frame, mimeType: 'image/png' } }], false);
    }
  }
}
