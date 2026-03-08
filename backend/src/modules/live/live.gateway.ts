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
  frame?: string; // Soporte para formato alternativo
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

  private readonly logger = new Logger(LiveGateway.name);

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
          'Eres hiBOB, una asistente mujer multimodal de nueva generación. Tu objetivo es potenciar la seguridad, la memoria y la productividad del usuario mediante visión artificial y análisis de datos en tiempo real. ' +
          'REGLA DE IDIOMA: Detecta automáticamente el idioma del usuario y responde en ese mismo idioma. ' +
          'TUS CAPACIDADES: ' +
          '1. ESCUDO DIGITAL: Si el usuario te muestra un enlace o SMS, utiliza capture_device_screen y analyze_security_url para protegerle de estafas usando VirusTotal. ' +
          '2. MEMORIA FOTOGRÁFICA: Si el usuario te enseña dónde deja algo, usa save_visual_memory. Para recuperarlo, usa get_visual_memory. ' +
          '3. MODO COPILOTO: Guía al usuario a usar su móvil o apps viendo su pantalla con capture_device_screen. ' +
          '4. VISIÓN DEL ENTORNO: Describe lo que ves con describe_camera_view cuando se te solicite. ' +
          'REGLA DE ORO: Para listas, noticias o recetas, usa display_content inmediatamente. ' +
          'REGLA VISUAL: Nunca inventes detalles. Si no tienes imagen clara, di que no puedes verla. ' +
          'IMPORTANTE: Ignora ruidos de fondo. Mantén un tono profesional, amable y proactivo.',
      });

      client.data.geminiSession = session;

      session.on('audio', (audio) => {
        if (!client.connected) return;
        client.emit('audio_chunk', { data: audio.data, mimeType: audio.mimeType || 'audio/pcm' });
      });

      session.on('transcription', (text) => {
        if (!client.connected) return;
        client.emit('transcription', { text });
      });

      session.on('interruption', () => {
        if (!client.connected) return;
        client.emit('interruption', {});
      });

      session.on('done', () => {
        if (!client.connected) return;
        client.emit('done', {});
      });

      session.on('close', (reason) => {
        this.logger.warn(`Gemini sesión cerrada para ${client.id}: ${reason || 'sin razón'}`);
        if (client.connected) {
          client.emit('error', { message: 'La conexión con la IA se ha reiniciado.' });
        }
      });

      session.on('tool_call', async (toolCall) => {
        const results = await Promise.all(
          toolCall.functionCalls.map(async (fc: any) => {
            // Herramientas visuales: pedir frame al móvil, enviarlo a Gemini y responder
            if (fc.name === 'detect_safety_hazards' || fc.name === 'describe_camera_view' || fc.name === 'capture_device_screen') {
              const isScreen = fc.name === 'capture_device_screen';
              this.logger.log(`Solicitando frame (${isScreen ? 'PANTALLA' : 'CÁMARA'}) para: ${fc.name}`);

              client.emit('frame_request', { source: isScreen ? 'screen' : 'camera' });
              const frameBase64 = await this._waitForFrame(client, 5000);

              if (!frameBase64) {
                return {
                  name: fc.name,
                  id: fc.id,
                  response: { content: 'ERROR: Imagen no recibida. Pide al usuario que abra la app.' },
                };
              }

              // Enviar la imagen al stream de Gemini para que la procese
              session.sendImageFrame(frameBase64, isScreen ? 'image/png' : 'image/jpeg');

              // Responder el tool call con confirmación para que Gemini analice la imagen
              const confirmMsg = isScreen
                ? 'PANTALLA CAPTURADA: Analiza la interfaz visible y guía al usuario paso a paso.'
                : 'IMAGEN CAPTURADA: Describe lo que ves de forma natural y detallada.';
              return { name: fc.name, id: fc.id, response: { content: confirmMsg } };
            }

            const result = await (this.aiService as any).executeTool(fc.name, fc.args, client.id);

            // Comandos de hardware y UI
            if (fc.name === 'toggle_flashlight') {
              client.emit('command', { action: 'flashlight', enabled: fc.args.enabled });
            } else if (fc.name === 'switch_camera') {
              client.emit('command', { action: 'switch_camera', direction: fc.args.direction });
            } else if (fc.name === 'trigger_haptic_feedback') {
              client.emit('command', { action: 'vibrate', pattern: fc.args.pattern });
            } else if (fc.name === 'display_content') {
              client.emit('display_content', {
                type: fc.args.type,
                title: fc.args.title,
                items: fc.args.items,
              });
            }

            return { name: fc.name, id: fc.id, response: { content: result } };
          }),
        );
        session.sendToolResponse(results);
      });

      session.on('error', (err) => {
        this.logger.error(`Error Gemini Live: ${err.message}`);
        if (client.connected) client.emit('error', { message: err.message });
      });

    } catch (err) {
      this.logger.error(`Error en handleConnection: ${err.message}`);
      client.disconnect();
    }
  }

  handleDisconnect(client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    session?.close();
    this.locationService.removeClientLocation(client.id);
    this.logger.log(`Cliente desconectado: ${client.id}`);
  }

  private _waitForFrame(client: Socket, timeoutMs: number): Promise<string | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        client.off('frame', handler);
        resolve(null);
      }, timeoutMs);
      const handler = (payload: FramePayload) => {
        clearTimeout(timer);
        resolve(payload?.frameBase64 || payload?.frame || null);
      };
      client.once('frame', handler);
    });
  }

  @SubscribeMessage('audio_chunk')
  handleAudioChunk(@MessageBody() payload: AudioChunkPayload, @ConnectedSocket() client: Socket) {
    try {
      const session = client.data.geminiSession as GeminiLiveSession;
      if (session && !session.isClosed() && payload?.audioBase64) {
        session.sendAudioFrame(payload.audioBase64, payload.mimeType || 'audio/pcm;rate=16000');
      }
    } catch (e) {
      this.logger.error(`Error procesando audio_chunk: ${e.message}`);
    }
  }

  @SubscribeMessage('frame')
  handleFrame(@MessageBody() payload: FramePayload, @ConnectedSocket() client: Socket) {
    try {
      const session = client.data.geminiSession as GeminiLiveSession;
      const frame = payload?.frameBase64 || payload?.frame;
      if (session && !session.isClosed() && frame) {
        session.sendImageFrame(frame);
      }
    } catch (e) {
      this.logger.error(`Error procesando frame: ${e.message}`);
    }
  }

  @SubscribeMessage('update_location')
  handleUpdateLocation(@MessageBody() payload: any, @ConnectedSocket() client: Socket) {
    if (payload?.latitude != null && payload?.longitude != null) {
      this.locationService.setClientLocation(client.id, {
        latitude: payload.latitude,
        longitude: payload.longitude,
        accuracy: payload.accuracy,
      });
    }
  }
}
