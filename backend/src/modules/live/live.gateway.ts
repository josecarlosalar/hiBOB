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
  server!: Server;

  private readonly logger = new Logger('LiveGateway-V2.8');

  constructor(
    private readonly aiService: AiService,
    private readonly locationService: LocationService,
  ) { }

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

      const session = this.aiService.createLiveSession({
        systemInstruction:
          'Eres BOB, un agente de seguridad experto en ciberseguridad. Tu tono es calmado, profesional y analítico. Nunca entres en pánico, pero sé firme en tus recomendaciones de seguridad. Siempre que el usuario mencione problemas con bancos, SMS o enlaces, tu prioridad es evitar que el usuario interactúe con ellos. Si el usuario te menciona una posible amenaza, ofrécele inmediatamente analizarla mediante una imagen (captura de pantalla) para verificar la URL. Usa tus herramientas de búsqueda y análisis para confirmar tus sospechas.' +
          'REGLA DE IDIOMA: Detecta automáticamente el idioma del usuario y responde SIEMPRE en ese mismo idioma. Si el usuario te habla en inglés, responde en inglés; si te habla en español, en español, etc. ' +
          'FLUJO DE SEGURIDAD: Cuando el usuario te muestre una captura de pantalla o foto, tu prioridad absoluta es identificar URLs, enlaces o mensajes sospechosos. ' +
          'Si ves una URL, utiliza SIEMPRE la herramienta analyze_security_url para verificarla con VirusTotal y dar un veredicto técnico. ' +
          'MODO COPILOTO: Si el usuario te pide ayuda con su móvil, guía sus pasos de forma natural. ' +
          'Responde de forma breve, proactiva y profesional.',
      });

      client.data.geminiSession = session;

      session.on('audio', (audio) => {
        if (!client.connected) return;
        client.emit('audio_chunk', { data: audio.data, mimeType: audio.mimeType || 'audio/pcm' });
      });

      session.on('transcription', (text) => {
        this.logger.log(`[Gemini] Transcripción: ${text}`);
        if (client.connected) client.emit('transcription', { text });
      });

      session.on('interruption', () => {
        if (client.connected) client.emit('interruption', {});
      });

      session.on('done', () => {
        if (client.connected) client.emit('done', {});
      });

      session.on('error', (err) => {
        this.logger.error(`[Gemini] Error en sesión: ${err.message || err}`);
        if (client.connected) client.emit('error', { message: err.message || 'Error de IA' });
      });

      session.on('close', () => {
        this.logger.warn(`[Gemini] Sesión cerrada para cliente ${client.id}`);
        // No desconectamos el socket automáticamente, permitimos reconexión de sesión si fuera necesario
      });

      session.on('tool_call', async (toolCall) => {
        this.logger.log(`[Gemini] Tool Call: ${JSON.stringify(toolCall)}`);
        const results = await Promise.all(
          toolCall.functionCalls.map(async (fc: any) => {
            // Manejo de herramientas visuales reactivas (BLOQUEANTES)
            if (fc.name === 'capture_device_screen' || fc.name === 'describe_camera_view' || fc.name === 'open_gallery') {
              const source = fc.name === 'capture_device_screen' ? 'screen' : (fc.name === 'open_gallery' ? 'gallery' : 'camera');
              client.emit('frame_request', { source });
              
              // Para la galería damos más tiempo (20s) porque el usuario debe elegir la foto
              const timeout = fc.name === 'open_gallery' ? 20000 : 10000;
              const frame = await this._waitForFrame(client, timeout);
              
              if (!frame) {
                return { 
                  name: fc.name, 
                  id: fc.id, 
                  response: { content: `ERROR: No se recibió ninguna imagen de la ${source === 'screen' ? 'pantalla' : (source === 'gallery' ? 'galería' : 'cámara')}.` } 
                };
              }

              // MOSTRAR EN PANTALLA (UI)
              client.emit('display_content', {
                type: 'detail',
                title: `Analizando ${source === 'screen' ? 'Captura' : (source === 'gallery' ? 'Galería' : 'Cámara')}`,
                items: [{
                    id: 'analysis_frame',
                    title: 'Imagen Capturada',
                    description: 'Procesando imagen con IA...',
                    imageUrl: `data:image/jpeg;base64,${frame}`
                }]
              });

              // Enviamos la imagen como contenido del cliente para que Gemini la "vea"
              session.sendClientContent([
                { text: `Aquí tienes la imagen solicitada (${source}). Analízala cuidadosamente.` },
                { inlineData: { data: frame, mimeType: 'image/jpeg' } }
              ]);
              
              return { name: fc.name, id: fc.id, response: { content: 'Imagen recibida y mostrada en pantalla. Ya puedes verla.' } };
            }

            // Ejecución de herramientas estándar (Búsqueda, VirusTotal, etc.)
            let result = await this.aiService.executeTool(fc.name, fc.args, client.id);

            // Manejo especial de VirusTotal para Feedback Gráfico
            if (fc.name === 'analyze_security_url') {
                try {
                    const data = JSON.parse(result);
                    const isDanger = data.positives > 0;
                    
                    client.emit('display_content', {
                        type: 'detail',
                        title: isDanger ? '🚨 Amenaza Detectada' : '✅ Enlace Seguro',
                        items: [
                            {
                                id: 'vt_report',
                                title: data.url,
                                description: `Resultado: ${data.positives}/${data.total} motores detectaron amenazas.\n\n` +
                                             `✅ Limpios: ${data.harmless}\n` +
                                             `⚠️ Sospechosos: ${data.suspicious}\n` +
                                             `🚫 Maliciosos: ${data.malicious}`,
                                imageUrl: isDanger 
                                    ? 'https://img.icons8.com/color/512/warning-shield.png'
                                    : 'https://img.icons8.com/color/512/verified-badge.png'
                            }
                        ]
                    });
                    result = `REPORTE TÉCNICO: La URL ${data.url} ha sido analizada. ${data.positives} de ${data.total} motores la marcan como sospechosa. He mostrado los detalles en pantalla.`;
                } catch (e) {
                    // Fallback si VirusTotal falló o devolvió error de API
                    if (result.includes('no configurado')) {
                        client.emit('display_content', {
                            type: 'detail',
                            title: 'Servicio no disponible',
                            items: [{
                                id: 'vt_error',
                                title: 'VirusTotal Offline',
                                description: 'No he podido realizar el análisis técnico automático, pero basándome en lo que veo en la captura, te daré mi veredicto manual.',
                                imageUrl: 'https://img.icons8.com/color/512/broken-robot.png'
                            }]
                        });
                    }
                }
            }

            // Emisión de comandos al móvil
            if (fc.name === 'toggle_flashlight') {
              client.emit('command', { action: 'flashlight', enabled: fc.args.enabled });
            } else if (fc.name === 'switch_camera') {
              client.emit('command', { action: 'switch_camera', direction: fc.args.direction });
            } else if (fc.name === 'trigger_haptic_feedback') {
              client.emit('command', { action: 'vibrate', pattern: fc.args.pattern });
            } else if (fc.name === 'display_content') {
              client.emit('display_content', { type: fc.args.type, title: fc.args.title, items: fc.args.items });
            }

            return { name: fc.name, id: fc.id, response: { content: result } };
          }),
        );
        session.sendToolResponse(results);
      });

      // Conectar después de haber configurado todos los listeners
      await session.connect();

    } catch (err) {
      this.logger.error(`Error en handleConnection: ${err instanceof Error ? err.message : err}`);
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
        client.data.pendingFrameResolve = null;
        resolve(null);
      }, timeoutMs);
      client.data.pendingFrameResolve = (frame: string | null) => {
        clearTimeout(timer);
        client.data.pendingFrameResolve = null;
        resolve(frame);
      };
    });
  }

  @SubscribeMessage('audio_chunk')
  handleAudioChunk(@MessageBody() payload: AudioChunkPayload, @ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (session && !session.isClosed() && payload?.audioBase64) {
      session.sendAudioFrame(payload.audioBase64, payload.mimeType || 'audio/pcm;rate=16000');
    }
  }

  @SubscribeMessage('frame')
  handleFrame(@MessageBody() payload: FramePayload, @ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    const frame = payload?.frameBase64 || payload?.frame;
    if (!session || session.isClosed() || !frame) return;

    // Si hay una solicitud de frame pendiente (tool call), resolver esa promesa
    if (client.data.pendingFrameResolve) {
      this.logger.log(`[Visión] Frame recibido para tool call de ${client.id}`);
      client.data.pendingFrameResolve(frame);
      return;
    }

    // Si no hay solicitud pendiente, es un frame proactivo (app minimizada)
    this.logger.log(`[Visión] Captura proactiva de ${client.id}`);
    session.sendClientContent([
      { text: "El usuario ha minimizado la app. Esta es su pantalla actual." },
      { inlineData: { data: frame, mimeType: 'image/jpeg' } }
    ], false);
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
