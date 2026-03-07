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
  frameBase64: string;
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
          'Eres hiBOB, una asistente mujer multimodal para personas con discapacidad visual. ' +
          'Habla siempre en ESPAÑOL DE ESPAÑA con un tono amable y profesional. ' +
          'Tienes acceso al micrófono del usuario de forma continua. ' +
          'Tienes "ojos": puedes ver a través de la cámara del móvil. ' +
          'Cuando el usuario te pregunte "¿qué ves?", "¿puedes verme?" o similar, utiliza la función describe_camera_view inmediatamente. ' +
          'Responde de forma concisa (máximo 3 frases) y natural. ' +
          'Cuando necesites un análisis de seguridad detallado (obstáculos, tráfico), usa detect_safety_hazards. ' +
          'IMPORTANTE: Ignora ruidos de fondo, eco o estática. No interrumpas tu propia respuesta a menos que escuches una instrucción clara y directa del usuario para que te detengas.',
      });

      client.data.geminiSession = session;
      this.logger.log(`Sesion Gemini Live lista para client=${client.id}`);

      session.on('audio', (audio) => {
        const base64Audio = audio?.data as string | undefined;
        const mimeType = (audio?.mimeType as string | undefined) ?? 'audio/pcm';
        if (!base64Audio) return;
        client.emit('audio_chunk', { data: base64Audio, mimeType });
      });

      session.on('transcription', (text) => {
        this.logger.log(`Gemini -> Cliente [transcription]: ${text.length} chars`);
        client.emit('transcription', { text });
      });

      session.on('interruption', () => {
        this.logger.log('Gemini -> Cliente [interruption]');
        client.emit('interruption', {});
      });

      session.on('done', () => {
        this.logger.log('Gemini -> Cliente [done]');
        client.emit('done', {});
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
            // Herramientas visuales: pedir frame al móvil antes de ejecutar
            if (fc.name === 'detect_safety_hazards' || fc.name === 'describe_camera_view') {
              this.logger.log(`Solicitando frame al cliente ${client.id} para herramienta visual: ${fc.name}`);
              client.emit('frame_request', {});
              // Esperar el frame (máx 4s)
              const frameBase64 = await this._waitForFrame(client, 4000);
              if (frameBase64) {
                session.sendImageFrame(frameBase64);
              } else {
                this.logger.warn(`No se recibió frame a tiempo para la herramienta ${fc.name}`);
                // Devolvemos un error explícito a la herramienta para que Gemini no alucine
                return {
                  name: fc.name,
                  id: fc.id,
                  response: { content: 'ERROR: No se ha podido capturar la imagen de la cámara a tiempo. Informa al usuario del problema técnico y no intentes describir nada.' },
                };
              }
            }

            const result = await (this.aiService as any).executeTool(fc.name, fc.args, client.id);

            if (fc.name === 'toggle_flashlight') {
              client.emit('command', { action: 'flashlight', enabled: fc.args.enabled });
            } else if (fc.name === 'switch_camera') {
              client.emit('command', { action: 'switch_camera', direction: fc.args.direction });
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

  /** Espera a que el cliente envíe un frame tras un frame_request. */
  private _waitForFrame(client: Socket, timeoutMs: number): Promise<string | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        client.off('frame', handler);
        resolve(null);
      }, timeoutMs);

      const handler = (payload: FramePayload) => {
        clearTimeout(timer);
        resolve(payload?.frameBase64 ?? null);
      };

      client.once('frame', handler);
    });
  }

  @SubscribeMessage('audio_chunk')
  handleAudioChunk(
    @MessageBody() payload: AudioChunkPayload,
    @ConnectedSocket() client: Socket,
  ) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (!session || session.isClosed()) return;

    if (payload?.audioBase64) {
      const mimeType = payload.mimeType ?? 'audio/pcm;rate=16000';
      session.sendAudioFrame(payload.audioBase64, mimeType);
    }
  }

  @SubscribeMessage('frame')
  handleFrame(
    @MessageBody() payload: FramePayload,
    @ConnectedSocket() client: Socket,
  ) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (!session || session.isClosed()) return;

    if (payload?.frameBase64) {
      this.logger.log(
        `Cliente -> Gemini [frame]: ${payload.frameBase64.length} chars`,
      );
      session.sendImageFrame(payload.frameBase64);
    }
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
}
