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
          'Eres hiBOB, una asistente mujer multimodal de nueva generación. ' +
          'TU MISIÓN: Ser el Guardián Digital y Copiloto del usuario. ' +
          'REGLA DE IDIOMA: Responde siempre en el idioma del usuario (español por defecto). ' +
          'MODO SEGURIDAD (ESCUDO DIGITAL): Si el usuario menciona SMS sospechosos, enlaces, links, mensajes extraños o posibles virus, utiliza SIEMPRE capture_device_screen para ver el contenido. NUNCA pidas que te lo lea ni uses la cámara para ver el software. Una vez capturada la pantalla, identifica la URL y utiliza analyze_security_url para dar un veredicto técnico basado en VirusTotal. ' +
          'MODO COPILOTO: Ayuda al usuario a navegar por su móvil. Si el usuario está perdido en los ajustes o una app, usa capture_device_screen para ver su pantalla y dale instrucciones paso a paso (ej. "Pulsa en el icono del engranaje que ves arriba a la derecha"). ' +
          'MEMORIA VISUAL: Guarda objetos/lugares con save_visual_memory ("hiBOB, recuerda donde dejo esto") y recupéralos con get_visual_memory. ' +
          'INTERRUPCIONES: Eres una asistente en vivo; si el usuario te interrumpe, deja de hablar inmediatamente y escucha. ' +
          'VISIÓN: Cuando uses describe_camera_view o capture_device_screen, sé descriptiva y natural. Si no recibes la imagen, di: "No he podido capturar la imagen, ¿puedes asegurarte de que estoy en primer plano y volver a intentarlo?".',
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
              this.logger.log(`[Tool] Ejecutando ${fc.name}. Solicitando frame a cliente ${client.id}...`);

              client.emit('frame_request', { source: isScreen ? 'screen' : 'camera' });
              
              // Aumentamos timeout a 10s para dar tiempo a la captura de pantalla de Android
              const frameBase64 = await this._waitForFrame(client, 10000);

              if (!frameBase64) {
                this.logger.warn(`[Tool] Timeout esperando frame de ${client.id} para ${fc.name}`);
                return {
                  name: fc.name,
                  id: fc.id,
                  response: { content: 'ERROR: No he recibido la imagen a tiempo. Asegúrate de estar en la pantalla que quieres que vea y que la app tenga los permisos necesarios.' },
                };
              }

              this.logger.log(`[Tool] Frame recibido (${frameBase64.length} bytes). Enviando a Gemini...`);
              
              // Enviar la imagen como un turno de usuario formal
              (session as any).sendClientContent([
                { text: "Aquí tienes la captura de mi pantalla actual. Analízala para ayudarme." },
                { inlineData: { data: frameBase64, mimeType: isScreen ? 'image/png' : 'image/jpeg' } }
              ]);
              
              return { 
                name: fc.name, 
                id: fc.id, 
                response: { content: 'Captura procesada con éxito. Ya puedes ver el contenido.' } 
              };
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
