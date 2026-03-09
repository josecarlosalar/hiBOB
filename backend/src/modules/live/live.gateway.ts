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

  private readonly logger = new Logger('LiveGateway-V2.5');

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
          'TU MISIÓN: Ser el Guardián Digital y Copiloto del usuario. ' +
          'REGLA DE IDIOMA: Responde siempre en el idioma del usuario (español por defecto). ' +
          'MODO SEGURIDAD (ESCUDO DIGITAL): Si el usuario menciona SMS sospechosos o enlaces extraños, usa capture_device_screen para ver el contenido. Luego usa analyze_security_url. ' +
          'MODO COPILOTO: Ayuda al usuario a navegar por su móvil viendo su pantalla con capture_device_screen. ' +
          'INTERRUPCIONES: Si el usuario te interrumpe, deja de hablar inmediatamente. ' +
          'VISIÓN: Al recibir una captura de pantalla o imagen de cámara, descríbela de forma natural y proactiva.',
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
            if (fc.name === 'detect_safety_hazards' || fc.name === 'describe_camera_view' || fc.name === 'capture_device_screen') {
              const isScreen = fc.name === 'capture_device_screen';
              this.logger.log(`[ToolCall] Solicitando imagen para ${fc.name}...`);

              client.emit('frame_request', { source: isScreen ? 'screen' : 'camera' });
              
              const frameBase64 = await this._waitForFrame(client, 10000);

              if (!frameBase64) {
                this.logger.warn(`[ToolCall] No se recibió imagen a tiempo para ${fc.name}`);
                return {
                  name: fc.name,
                  id: fc.id,
                  response: { content: 'ERROR: No puedo ver tu pantalla. Asegúrate de que no estoy minimizado y vuelve a intentarlo.' },
                };
              }

              this.logger.log(`[ToolCall] Imagen recibida (${frameBase64.length} bytes). Enviando como turno visual.`);
              
              (session as any).sendClientContent([
                { text: isScreen ? "Aquí tienes la captura de mi pantalla actual." : "Aquí tienes la imagen de mi cámara." },
                { inlineData: { data: frameBase64, mimeType: isScreen ? 'image/png' : 'image/jpeg' } }
              ]);
              
              return { name: fc.name, id: fc.id, response: { content: 'Imagen recibida. Analizando contenido...' } };
            }

            const result = await (this.aiService as any).executeTool(fc.name, fc.args, client.id);

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
        this.logger.log(`[Frame] Recibida captura proactiva de ${client.id} (${frame.length} bytes)`);
        // Enviar como turno formal para que Gemini ya lo tenga en memoria
        (session as any).sendClientContent([
          { text: "El usuario ha minimizado la app. Aquí tienes lo que está viendo ahora mismo." },
          { inlineData: { data: frame, mimeType: 'image/png' } }
        ], false); // turnComplete = false para que no empiece a hablar solo
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
