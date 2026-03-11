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
  fileName?: string;
}

@WebSocketGateway({
  cors: { origin: '*' },
  namespace: 'live',
  pingInterval: 25000,
  pingTimeout: 30000,
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

      // Obtener nombre del usuario desde Firebase Auth y usar solo el primer nombre
      const userRecord = await admin.auth().getUser(decoded.uid);
      const fullDisplayName = userRecord.displayName || userRecord.email?.split('@')[0] || 'amigo';
      const firstName = fullDisplayName.trim().split(' ')[0];
      this.logger.log(`Cliente conectado: ${client.id} (uid=${decoded.uid}, name=${fullDisplayName}, usedName=${firstName})`);

      const session = this.aiService.createLiveSession({
        systemInstruction:
          `Eres hiBOB, un agente de seguridad experto en ciberseguridad. El usuario que tienes delante se llama ${firstName}. ` +
          `Ya le conoces — eres su guardián digital de confianza. Salúdale de forma proactiva, breve y natural por su nombre en cuanto se conecte, como quien retoma una conversación. ` +
          'Tu tono es calmado, profesional y analítico. Nunca entres en pánico, pero sé firme en tus recomendaciones de seguridad. ' +

          'REGLAS CRÍTICAS DE SEGURIDAD: ' +
          '1. LENGUAJE DE RIESGO: Nunca digas que algo es "100% seguro" o "totalmente confiable". Habla siempre en términos de "reputación", "riesgo bajo/alto" o "sin amenazas detectadas por el momento". ' +
          '2. DISCLAIMER: Tras cada análisis de URL o archivo, incluye siempre un aviso breve: "Recuerda que ninguna herramienta es infalible; mantén la precaución". ' +
          '3. ALUCINACIONES: Si una herramienta devuelve un error o no tiene datos, admítelo. No inventes resultados. ' +

          'HERRAMIENTAS DISPONIBLES Y CUÁNDO USARLAS: ' +
          '• analyze_security_url → cuando el usuario mencione o muestre una URL completa (https://...). ' +
          '• analyze_domain → cuando el usuario mencione un dominio sin URL completa (ejemplo: google.com). ' +
          '• analyze_ip → cuando el usuario mencione una dirección IP numérica. ' +
          '• analyze_file_hash → cuando el usuario proporcione un hash SHA256/MD5/SHA1 de un archivo. ' +
          '• scan_file → cuando el usuario quiera analizar un archivo (APK, PDF, ejecutable) que tiene en su dispositivo. ' +
          '• scan_qr_code → cuando el usuario quiera verificar un código QR antes de escanearlo. ' +
          '• check_password_breach → cuando el usuario quiera saber si su contraseña ha sido filtrada. ' +
          '• generate_password → cuando el usuario necesite una contraseña nueva y segura. ' +
          '• capture_device_screen → Úsala SOLO cuando el usuario te pida ver lo que está pasando AHORA MISMO en su pantalla de forma interactiva (ej. mientras navega). ' +
          '• open_gallery → Úsala SIEMPRE que el usuario mencione que tiene una "captura", "pantallazo", "foto", "imagen" o "fichero" que quiere enseñarte. ' +
          '  - Usa el argumento { source: "gallery" } para imágenes y capturas. ' +
          '  - Usa el argumento { source: "files" } para documentos, PDFs o ficheros arbitrarios. ' +
          '  Es la opción preferida para analizar SMS o correos ya recibidos. ' +
          '• web_search → para información actualizada sobre amenazas, vulnerabilidades o empresas. Úsala también si VirusTotal da "limpio" pero sospechas que es una estafa muy nueva. ' +

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
        // pendingClientContent: contenido a enviar DESPUÉS del sendToolResponse (para imágenes de galería)
        let pendingClientContent: any[] | null = null;

        const results = await Promise.all(
          toolCall.functionCalls.map(async (fc: any) => {
            // open_gallery: flujo para obtener imagen de la galería
            if (fc.name === 'open_gallery') {
              const source = fc.args.source || 'gallery';
              this.logger.log(`[Herramienta] Solicitando imagen/fichero (${source}) para ${client.id}...`);
              client.emit('command', { action: 'open_gallery', source });
              
              // Esperamos hasta 60s a que el usuario elija la imagen
              const payload = await this._waitForFrame(client, 60000);
              const frame = payload?.frameBase64 || payload?.frame;

              if (!frame) {
                return { 
                  name: fc.name, 
                  id: fc.id, 
                  response: { content: 'El usuario no seleccionó ningún elemento o tardó demasiado.' } 
                };
              }

              // Si viene con fileName es un fichero arbitrario → analizar con VirusTotal
              if (payload?.fileName) {
                const fileName = payload.fileName;
                this.logger.log(`[Fichero] Fichero recibido: ${fileName}`);
                client.emit('display_content', {
                  type: 'file_scan',
                  title: 'Analizando Fichero',
                  items: [{ id: 'scan_progress', title: fileName, description: 'Subiendo a VirusTotal...' }]
                });

                const vtResult = await this.aiService.executeTool('scan_file_data', { fileBase64: frame, fileName }, client.id);
                client.emit('display_content', {
                  type: 'file_scan',
                  title: 'Analizando Fichero',
                  items: [{ id: 'scan_progress', title: fileName, description: 'Generando diagnóstico...' }]
                });
                try {
                  const data = JSON.parse(vtResult);
                  this._emitVtReport(client, data, fileName);
                  return {
                    name: fc.name,
                    id: fc.id,
                    response: { content: `Fichero "${fileName}" analizado. VirusTotal: ${data.positives}/${data.total} motores detectaron amenaza. Resultado en pantalla.` }
                  };
                } catch {
                  return { name: fc.name, id: fc.id, response: { content: `Error analizando fichero: ${vtResult}` } };
                }
              }

              // Mostramos en la UI para feedback visual inmediato (sin base64 para evitar destellos)
              client.emit('display_content', {
                type: 'file_scan',
                title: 'Analizando Imagen',
                items: [{
                    id: 'scan_progress',
                    title: 'Imagen de Galería',
                    description: 'Enviando imagen a Gemini...',
                }]
              });

              // Guardar imagen para enviar DESPUÉS del sendToolResponse (evita race condition)
              pendingClientContent = [
                { text: 'Aquí tienes la imagen de la galería que solicitaste. Analízala detalladamente y responde al usuario.' },
                { inlineData: { data: frame, mimeType: 'image/jpeg' } }
              ];

              return {
                name: fc.name,
                id: fc.id,
                response: { content: 'Imagen recibida. Analizando ahora...' }
              };
            }

            // Manejo de herramientas visuales reactivas (BLOQUEANTES)
            if (fc.name === 'capture_device_screen' || fc.name === 'describe_camera_view') {
              const source = fc.name === 'capture_device_screen' ? 'screen' : 'camera';
              client.emit('frame_request', { source });

              const timeout = fc.name === 'describe_camera_view' ? 40000 : 10000;
              const payload = await this._waitForFrame(client, timeout);
              const frame = payload?.frameBase64 || payload?.frame;

              if (!frame) {
                return {
                  name: fc.name,
                  id: fc.id,
                  response: { content: `ERROR: No se recibió ninguna imagen de la ${source === 'screen' ? 'pantalla' : 'cámara'}.` }
                };
              }

              // MOSTRAR EN PANTALLA (UI)
              client.emit('display_content', {
                type: 'detail',
                title: `Analizando ${source === 'screen' ? 'Captura' : 'Cámara'}`,
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
              const payload = await this._waitForFrame(client, 40000);
              const qrFrame = payload?.frameBase64 || payload?.frame;
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

            // ── Scan File: solicita archivo y lo sube a VT ──
            if (fc.name === 'scan_file') {
              this.logger.log(`[Herramienta] Solicitando fichero para VirusTotal para ${client.id}...`);
              client.emit('command', { action: 'open_gallery', source: 'files' });
              
              const payload = await this._waitForFrame(client, 60000);
              const fileFrame = payload?.frameBase64 || payload?.frame;
              
              if (!fileFrame) {
                return { name: fc.name, id: fc.id, response: { content: 'No se recibió el archivo o el usuario canceló.' } };
              }
              
              const fileName = payload.fileName || fc.args.fileName || 'archivo';
              client.emit('display_content', {
                type: 'file_scan',
                title: 'Analizando archivo...',
                items: [{ id: 'scan_progress', title: fileName, description: 'Subiendo a VirusTotal...' }],
              });
              
              const vtResult = await this.aiService.executeTool('scan_file_data', { fileBase64: fileFrame, fileName }, client.id);
              client.emit('display_content', {
                type: 'file_scan',
                title: 'Analizando archivo...',
                items: [{ id: 'scan_progress', title: fileName, description: 'Generando diagnóstico...' }],
              });
              try {
                const data = JSON.parse(vtResult);
                this._emitVtReport(client, data, fileName);
                return { name: fc.name, id: fc.id, response: { content: `Análisis de "${fileName}" completado. ${data.positives}/${data.total} motores detectaron amenaza. Resultado visible en pantalla.` } };
              } catch {
                return { name: fc.name, id: fc.id, response: { content: `Error analizando fichero: ${vtResult}` } };
              }
            }

            // Feedback visual de "pensando" para herramientas de red
            if (['analyze_security_url', 'analyze_domain', 'analyze_ip', 'analyze_file_hash', 'web_search', 'check_password_breach'].includes(fc.name)) {
              client.emit('thinking_state', { tool: fc.name, message: this._getThinkingMessage(fc.name) });
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
                } else if (data.pending) {
                  this.logger.warn(`[VT-URL] Análisis pendiente: ${data.message}`);
                  client.emit('display_content', { type: 'vt_report', title: 'Análisis en Cola', vtData: { url: data.url ?? fc.args.url, positives: 0, total: 0, threatLevel: 'unknown', isDanger: false, scanDate: new Date().toLocaleString('es-ES') } });
                  result = `El análisis de VirusTotal está en cola (URL nueva). ${data.message} Informa al usuario y recomienda precaución mientras tanto.`;
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

        // Enviar imagen DESPUÉS del tool response para que Gemini la reciba en el turno correcto
        if (pendingClientContent) {
          await new Promise(resolve => setTimeout(resolve, 150));
          session.sendClientContent(pendingClientContent);
        }
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

  private _waitForFrame(client: Socket, timeoutMs: number): Promise<FramePayload | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        client.data.pendingFrameResolve = null;
        resolve(null);
      }, timeoutMs);
      client.data.pendingFrameResolve = (payload: FramePayload | null) => {
        clearTimeout(timer);
        client.data.pendingFrameResolve = null;
        resolve(payload);
      };
    });
  }

  private _getThinkingMessage(toolName: string): string {
    const messages = {
      analyze_security_url: 'Analizando URL con VirusTotal...',
      analyze_domain: 'Consultando reputación del dominio...',
      analyze_ip: 'Verificando dirección IP sospechosa...',
      analyze_file_hash: 'Buscando hash en bases de datos de malware...',
      web_search: 'Buscando reportes de amenazas recientes en la web...',
      check_password_breach: 'Verificando filtraciones de seguridad...',
    };
    return messages[toolName] || 'Procesando...';
  }

  @SubscribeMessage('audio_chunk')
  handleAudioChunk(@MessageBody() payload: AudioChunkPayload, @ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (session && !session.isClosed() && payload?.audioBase64) {
      // Log de depuración: solo imprimimos uno de cada 50 para no inundar el log
      if (Math.random() < 0.02) this.logger.debug(`Recibido audio_chunk de cliente ${client.id} (size: ${payload.audioBase64.length})`);
      session.sendAudioFrame(payload.audioBase64, payload.mimeType || 'audio/pcm;rate=16000');
    }
  }

  @SubscribeMessage('frame')
  handleFrame(@MessageBody() payload: FramePayload, @ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    const frame = payload?.frameBase64 || payload?.frame;
    if (!session || session.isClosed() || !frame) return;

    // PRIORIDAD 1: Si el agente ha pedido una imagen (Tool Call / Aceptar),
    // esta imagen es la respuesta a esa solicitud.
    if (client.data.pendingFrameResolve) {
      this.logger.log(`[Visión] ¡IMAGEN RECIBIDA! Resolviendo espera para el cliente ${client.id}`);
      const resolve = client.data.pendingFrameResolve;
      client.data.pendingFrameResolve = null; 
      resolve(payload);
      return;
    }

    // PRIORIDAD 2: El usuario envió una imagen manualmente (botón de galería en la UI).
    // Si viene con prompt 'analyze_image', instruir a Gemini para que la analice.
    if (payload?.prompt === 'analyze_image') {
      this.logger.log(`[Visión] Imagen manual recibida para análisis directo en ${client.id}`);
      client.emit('display_content', {
        type: 'file_scan',
        title: 'Analizando Imagen',
        items: [{ id: 'scan_progress', title: 'Imagen de Galería', description: 'Analizando con Gemini...' }]
      });
      session.sendClientContent([
        { text: 'El usuario ha seleccionado esta imagen de su galería para que la analices en detalle. Descríbela, identifica cualquier amenaza de seguridad, URL sospechosa, QR, texto relevante o cualquier problema que detectes. Responde de forma clara y útil.' },
        { inlineData: { data: frame, mimeType: 'image/jpeg' } }
      ], true);
      return;
    }

    // PRIORIDAD 3: Captura proactiva (ej. el usuario minimizó la app)
    // Solo enviamos capturas proactivas si no estamos esperando una respuesta crítica.
    this.logger.log(`[Visión] Captura proactiva para ${client.id}`);
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
