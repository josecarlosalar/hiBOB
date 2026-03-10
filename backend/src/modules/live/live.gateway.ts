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

      // Obtener nombre del usuario desde Firebase Auth
      const userRecord = await admin.auth().getUser(decoded.uid);
      const displayName = userRecord.displayName || userRecord.email?.split('@')[0] || 'amigo';
      this.logger.log(`Cliente conectado: ${client.id} (uid=${decoded.uid}, name=${displayName})`);

      const session = this.aiService.createLiveSession({
        systemInstruction:
          `Eres hiBOB, un agente de seguridad experto en ciberseguridad. El usuario que tienes delante se llama ${displayName}. ` +
          `Ya le conoces — eres su guardián digital de confianza. Actúa como alguien que ya tiene relación con él: cuando te salude, respóndele por su nombre de forma natural y directa, sin presentarte ni explicar quién eres a menos que él te lo pregunte expresamente. ` +
          'Tu tono es calmado, profesional y analítico. Nunca entres en pánico, pero sé firme en tus recomendaciones de seguridad. ' +

          'HERRAMIENTAS DISPONIBLES Y CUÁNDO USARLAS: ' +
          '• analyze_security_url → cuando el usuario mencione o muestre una URL completa (https://...). ' +
          '• analyze_domain → cuando el usuario mencione un dominio sin URL completa (ejemplo: google.com). ' +
          '• analyze_ip → cuando el usuario mencione una dirección IP numérica. ' +
          '• analyze_file_hash → cuando el usuario proporcione un hash SHA256/MD5/SHA1 de un archivo. ' +
          '• scan_file → cuando el usuario quiera analizar un archivo (APK, PDF, ejecutable) que tiene en su dispositivo. ' +
          '• scan_qr_code → cuando el usuario quiera verificar un código QR antes de escanearlo. ' +
          '• check_password_breach → cuando el usuario quiera saber si su contraseña ha sido filtrada. ' +
          '• generate_password → cuando el usuario necesite una contraseña nueva y segura. ' +
          '• capture_device_screen → cuando necesites ver la pantalla del usuario para analizar un enlace, SMS, email o cualquier amenaza visual. ' +
          '• open_gallery → cuando el usuario quiera analizar una foto o captura que ya tiene guardada. ' +
          '• web_search → para información actualizada sobre amenazas, vulnerabilidades o empresas. ' +

          'REGLA DE IDIOMA: Detecta automáticamente el idioma del usuario y responde SIEMPRE en ese mismo idioma. ' +

          'FLUJO DE SEGURIDAD: Cuando el usuario mencione un enlace, IP, dominio o archivo sospechoso, ACTÚA inmediatamente con la herramienta correspondiente sin pedir permiso. ' +
          'Cuando veas una URL en pantalla, analízala con analyze_security_url. ' +
          'Ante un QR desconocido, usa scan_qr_code antes de que el usuario lo escanee. ' +

          'MODO COPILOTO: Si el usuario te pide ayuda con su móvil, guía sus pasos de forma natural. ' +

          'RESPUESTAS CORTAS: 1-3 frases máximo. Los datos numéricos y gráficos ya se muestran en pantalla, no los repitas. Tras cualquier análisis, da solo el veredicto y la recomendación de acción.',
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

            // ── QR Code: activa cámara y luego analiza la URL extraída ──────
            if (fc.name === 'scan_qr_code') {
              client.emit('frame_request', { source: 'camera' });
              const qrFrame = await this._waitForFrame(client, 15000);
              if (!qrFrame) {
                return { name: fc.name, id: fc.id, response: { content: 'No se recibió imagen de la cámara.' } };
              }
              // Mostramos la imagen capturada con animación de escaneo
              client.emit('display_content', {
                type: 'qr_scan',
                title: 'Escaneando QR...',
                items: [{ id: 'qr_frame', title: 'Imagen capturada', imageUrl: `data:image/jpeg;base64,${qrFrame}` }],
              });
              // Pedimos a Gemini que extraiga la URL del QR
              const session = client.data.geminiSession as any;
              session?.sendClientContent([
                { text: 'Extrae la URL o texto de este código QR. Responde SOLO con la URL, sin nada más.' },
                { inlineData: { data: qrFrame, mimeType: 'image/jpeg' } },
              ]);
              return { name: fc.name, id: fc.id, response: { content: 'QR capturado. Analizando URL extraída con VirusTotal automáticamente.' } };
            }

            // ── Scan File: solicita archivo desde galería y lo sube a VT ──
            if (fc.name === 'scan_file') {
              client.emit('frame_request', { source: 'gallery' });
              const fileFrame = await this._waitForFrame(client, 30000);
              if (!fileFrame) {
                return { name: fc.name, id: fc.id, response: { content: 'No se recibió el archivo.' } };
              }
              client.emit('display_content', {
                type: 'file_scan',
                title: 'Analizando archivo...',
                items: [{ id: 'scan_progress', title: fc.args.fileName ?? 'archivo', description: 'Subiendo a VirusTotal...' }],
              });
              const vtResult = await this.aiService.executeTool('scan_file_data', { fileBase64: fileFrame, fileName: fc.args.fileName ?? 'archivo' }, client.id);
              const data = JSON.parse(vtResult);
              this._emitVtReport(client, data, fc.args.fileName ?? 'archivo');
              return { name: fc.name, id: fc.id, response: { content: `Análisis completado. ${data.positives}/${data.total} motores detectaron amenaza. Resultado visible en pantalla.` } };
            }

            // Ejecución de herramientas estándar
            let result = await this.aiService.executeTool(fc.name, fc.args, client.id);

            // ── VirusTotal URL ────────────────────────────────────────────
            if (fc.name === 'analyze_security_url') {
              this.logger.log(`[VT-URL] Resultado raw: ${result}`);
              try {
                const data = JSON.parse(result);
                if (data.error) {
                  this.logger.warn(`[VT-URL] VirusTotal devolvió error: ${data.error}`);
                  client.emit('display_content', { type: 'vt_report', title: 'Error en análisis', vtData: { url: data.url ?? fc.args.url, positives: 0, total: 0, threatLevel: 'unknown', isDanger: false, scanDate: new Date().toLocaleString('es-ES') } });
                  result = `No se pudo analizar la URL en este momento. ${data.error}`;
                } else {
                  this._emitVtReport(client, data, data.url ?? fc.args.url);
                  result = `VT_RESULT:${data.positives > 0 ? 'PELIGRO' : 'LIMPIO'}. ${data.positives}/${data.total} motores. Veredicto en pantalla. Da veredicto en 1-2 frases.`;
                }
              } catch (e) {
                this.logger.error(`[VT-URL] Error al parsear resultado: ${e.message} | raw: ${result}`);
                client.emit('display_content', { type: 'vt_report', title: 'Servicio no disponible', vtData: null });
              }
            }

            // ── VirusTotal IP ─────────────────────────────────────────────
            if (fc.name === 'analyze_ip') {
              try {
                const data = JSON.parse(result);
                const isDanger = data.positives > 0;
                client.emit('display_content', {
                  type: 'ip_report',
                  title: isDanger ? 'IP Maliciosa Detectada' : 'IP Sin Amenazas',
                  ipData: {
                    ip: data.ip,
                    country: data.country ?? 'Desconocido',
                    asOwner: data.asOwner ?? 'Desconocido',
                    network: data.network ?? '',
                    reputation: data.reputation ?? 0,
                    positives: data.positives,
                    total: data.total,
                    malicious: data.malicious ?? 0,
                    suspicious: data.suspicious ?? 0,
                    harmless: data.harmless ?? 0,
                    isDanger,
                    threatLevel: isDanger ? (data.malicious > 5 ? 'critical' : 'dangerous') : 'clean',
                  },
                });
                result = `IP_RESULT:${isDanger ? 'PELIGROSA' : 'LIMPIA'}. Pertenece a ${data.asOwner ?? 'desconocido'} (${data.country ?? '??'}). Veredicto en pantalla.`;
              } catch { /* usa result tal cual */ }
            }

            // ── VirusTotal Dominio ────────────────────────────────────────
            if (fc.name === 'analyze_domain') {
              try {
                const data = JSON.parse(result);
                const isDanger = data.positives > 0;
                client.emit('display_content', {
                  type: 'domain_report',
                  title: isDanger ? 'Dominio Sospechoso' : 'Dominio Limpio',
                  domainData: {
                    domain: data.domain,
                    registrar: data.registrar ?? 'Desconocido',
                    creationDate: data.creationDate ?? 'Desconocida',
                    categories: data.categories ?? 'Sin categoría',
                    reputation: data.reputation ?? 0,
                    positives: data.positives,
                    total: data.total,
                    malicious: data.malicious ?? 0,
                    suspicious: data.suspicious ?? 0,
                    isDanger,
                    threatLevel: isDanger ? (data.malicious > 5 ? 'critical' : 'dangerous') : 'clean',
                  },
                });
                result = `DOMAIN_RESULT:${isDanger ? 'PELIGROSO' : 'LIMPIO'}. Registrado por ${data.registrar ?? '?'} el ${data.creationDate ?? '?'}. Veredicto en pantalla.`;
              } catch { /* usa result tal cual */ }
            }

            // ── VirusTotal Hash ───────────────────────────────────────────
            if (fc.name === 'analyze_file_hash') {
              try {
                const data = JSON.parse(result);
                this._emitVtReport(client, data, data.fileName ?? data.hash?.slice(0, 16) + '...');
                result = `HASH_RESULT:${data.positives > 0 ? 'MALWARE DETECTADO' : 'LIMPIO'}. ${data.positives}/${data.total} motores. Veredicto en pantalla.`;
              } catch { /* usa result tal cual */ }
            }

            // ── Contraseña comprometida ───────────────────────────────────
            if (fc.name === 'check_password_breach') {
              try {
                const data = JSON.parse(result);
                client.emit('display_content', {
                  type: 'password_check',
                  title: data.pwned ? 'Contraseña Comprometida' : 'Contraseña Segura',
                  passwordData: {
                    pwned: data.pwned,
                    count: data.count,
                    threatLevel: data.pwned ? (data.count > 10000 ? 'critical' : 'dangerous') : 'clean',
                  },
                });
                result = data.pwned
                  ? `BREACH: Esta contraseña apareció ${data.count.toLocaleString()} veces en filtraciones. Resultado en pantalla.`
                  : `SAFE: Esta contraseña no aparece en filtraciones conocidas. Resultado en pantalla.`;
              } catch { /* usa result tal cual */ }
            }

            // ── Generador de contraseña ───────────────────────────────────
            if (fc.name === 'generate_password') {
              try {
                const data = JSON.parse(result);
                client.emit('display_content', {
                  type: 'password_generated',
                  title: 'Contraseña Segura Generada',
                  passwordData: {
                    password: data.password,
                    length: data.length,
                    entropy: Math.floor(data.length * Math.log2(94)),
                  },
                });
                result = `Contraseña de ${data.length} caracteres generada y mostrada en pantalla. No la compartas por chat o SMS.`;
              } catch { /* usa result tal cual */ }
            }

            // ── Comandos al móvil ─────────────────────────────────────────
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

  private _emitVtReport(client: Socket, data: any, label: string) {
    const isDanger = (data.positives ?? 0) > 0;
    const threatLevel = data.positives === 0 ? 'clean'
      : data.positives <= 3 ? 'suspicious'
      : data.positives <= 10 ? 'dangerous'
      : 'critical';
    const scanDate = new Date().toLocaleString('es-ES', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
    client.emit('display_content', {
      type: 'vt_report',
      title: isDanger ? 'Amenaza Detectada' : 'Análisis Limpio',
      vtData: {
        url: label,
        positives: data.positives ?? 0,
        total: data.total ?? 0,
        harmless: data.harmless ?? 0,
        suspicious: data.suspicious ?? 0,
        malicious: data.malicious ?? 0,
        undetected: data.undetected ?? 0,
        fileName: data.fileName,
        fileType: data.fileType,
        fileSize: data.fileSize,
        threatLevel,
        isDanger,
        scanDate,
      },
    });
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

    // PRIORIDAD CRÍTICA: Si el agente ha pedido una imagen (Tool Call / Aceptar),
    // esta imagen es la respuesta a esa solicitud.
    if (client.data.pendingFrameResolve) {
      this.logger.log(`[Visión] ¡IMAGEN RECIBIDA! Resolviendo espera para el cliente ${client.id}`);
      const resolve = client.data.pendingFrameResolve;
      client.data.pendingFrameResolve = null; // Limpiamos inmediatamente para evitar duplicados
      resolve(frame);
      return;
    }

    // Si NO hay una solicitud pendiente, es una captura proactiva (ej. el usuario minimizó la app)
    // Solo enviamos capturas proactivas si no estamos esperando una respuesta crítica.
    this.logger.log(`[Visión] Captura proactiva ignorada o procesada como segundo plano para ${client.id}`);
    session.sendClientContent([
      { text: "El usuario está interactuando con su móvil. Esta es su vista actual de pantalla." },
      { inlineData: { data: frame, mimeType: 'image/jpeg' } }
    ], false); // turnComplete = false para no interrumpir el flujo de voz
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
