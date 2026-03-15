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
import { Jimp } from 'jimp';
import jsQR from 'jsqr';

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

  // Mapa para persistir sesiones por UID (permite reconexiones sin perder el hilo)
  private activeSessions = new Map<string, {
    session: GeminiLiveSession,
    disconnectTimer?: NodeJS.Timeout,
    lastClientId: string
  }>();

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
      const uid = decoded.uid;
      client.data.uid = uid;

      // Obtener nombre del usuario desde Firebase Auth
      const userRecord = await admin.auth().getUser(uid);
      const fullDisplayName = userRecord.displayName || userRecord.email?.split('@')[0] || 'amigo';
      const firstName = fullDisplayName.trim().split(' ')[0];

      // RECONEXIÓN: ¿Ya existe una sesión para este usuario?
      const sessionData = this.activeSessions.get(uid);

      if (sessionData) {
        this.logger.log(`[Reconexión] Recuperando sesión para ${firstName} (uid: ${uid}). Nuevo socket: ${client.id}`);
        if (sessionData.disconnectTimer) {
          clearTimeout(sessionData.disconnectTimer);
          sessionData.disconnectTimer = undefined;
        }
        sessionData.lastClientId = client.id;
        const session = sessionData.session;
        client.data.geminiSession = session;
        
        // Re-vincular listeners al nuevo socket
        this._setupSessionListeners(client, session);
        this.logger.log(`[Reconexión] Sesión re-vinculada con éxito para ${client.id}`);
        return;
      }

      this.logger.log(`Cliente conectado: ${client.id} (uid=${uid}, name=${fullDisplayName}, usedName=${firstName})`);
      
      // Obtener preferencias del usuario desde Firestore
      const userSettingsSnap = await admin.firestore().collection('users').doc(uid).get();
      const userSettings = userSettingsSnap.data() || {};
      const voiceName = userSettings.voiceName || 'Aoede';
      this.logger.log(`Preferencias de usuario: voiceName=${voiceName}`);

      const session = this.aiService.createLiveSession({
        voiceName,
        systemInstruction:
          `Eres hiBOB, un agente de seguridad experto en ciberseguridad. El usuario que tienes delante se llama ${firstName}. ` +
          `Ya le conoces — eres su guardián digital de confianza. Salúdale de forma proactiva, breve y natural por su nombre en cuanto se conecte, como quien retoma una conversación. ` +
          'Tu tono es calmado, profesional y analítico. Nunca entres en pánico, pero sé firme en tus recomendaciones de seguridad. ' +

          'MODO COPILOTO Y COMUNICACIÓN: ' +
          'Detecta automáticamente el idioma del usuario y responde SIEMPRE en ese mismo idioma. Si es español, usa español de España. ' +
          'Habla de forma natural, fluida, empática y directa. No suenes robótico, evita explicaciones técnicas largas y listas interminables. ' +
          'Si el usuario te pide ayuda con su móvil, guía sus pasos de forma natural como un copiloto experto. ' +

          'PRESENTACIÓN DE CAPACIDADES VISUALES (CRÍTICO): ' +
          'Si el usuario te pregunta "cómo puedes ayudarme", "qué sabes hacer", "explícame qué haces" o similares, DEBES usar OBLIGATORIAMENTE la herramienta "display_content" al mismo tiempo que inicias tu respuesta de voz. ' +
          'Llama a "display_content" con el argumento { "contentType": "features_slider", "title": "Mis Capacidades" } y añade al menos 4 "items" interactivos asegurándote de rellenar los campos "id", "title", y "description" de cada uno detallando tus funciones (ej: Análisis VirusTotal, Revisión de Contraseñas Filtradas, Protección de Red, Modo Copiloto). ' +
          'Mientras envías el comando visual, explica por voz y con detalle TODO lo que puedes hacer usando tu acceso a VirusTotal, Have I Been Pwned y la búsqueda web. Esto generará un carrusel slider en pantalla sincronizado con tu voz. ' +

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
          '• scan_qr_code → OBLIGATORIO llamar INMEDIATAMENTE cuando el usuario mencione un QR, código QR, escanear código QR, escanear QR, verificar QR o cualquier variante explícita de QR. NO respondas por voz primero: llama scan_qr_code YA y simultáneamente dile al usuario que abres la cámara. ' +
          '• trigger_qr_capture → SOLO cuando el sistema esté esperando la captura del QR (el usuario ve el visor QR en pantalla) y el usuario diga por voz que ya lo tiene encuadrado (ej: "listo", "ya", "captura", "hazlo", "ahora"). Responde con "¡Capturando!" y llama esta herramienta de inmediato. ' +
          '• check_password_breach → cuando el usuario quiera saber si su contraseña ha sido filtrada. ' +
          '• generate_password → cuando el usuario necesite una contraseña nueva y segura. ' +
          '• capture_device_screen → Úsala SOLO cuando el usuario te pida ver lo que está pasando AHORA MISMO en su pantalla de forma interactiva (ej. mientras navega). ' +
          '• open_gallery → Úsala SIEMPRE que el usuario mencione que tiene una "captura", "pantallazo", "foto", "imagen" o "fichero" que quiere enseñarte. ' +
          '  - Usa el argumento { source: "gallery" } para imágenes y capturas. ' +
          '  - Usa el argumento { source: "files" } para documentos, PDFs o ficheros arbitrarios. ' +
          '  Es la opción preferida para analizar SMS o correos ya recibidos. ' +
          '• describe_camera_view → Úsala SOLO cuando el usuario te PREGUNTE qué ves, qué hay delante, o deba analizar su entorno/cara. Pide "direction: front" o "back". Primero abrirá la cámara si no lo estaba, hará una captura y emitirá su diagnóstico por voz. ' +
          '• web_search → para información actualizada sobre amenazas, vulnerabilidades o empresas. Úsala también si VirusTotal da "limpio" pero sospechas que es una estafa muy nueva. ' +
          '• toggle_flashlight → Úsala cuando el usuario te pida encender (enabled: true) o apagar (enabled: false) la luz / linterna del móvil. ' +
          '• switch_camera → Úsala para ACTIVAR o CAMBIAR la vista de vídeo en vivo a pantalla completa (direction: "front" o "back"). Úsala cuando el usuario quiera VER su cámara de forma activa (ej. "Activa la cámara", "Abre la cámara trasera"). NUNCA uses "describe_camera_view" si el usuario SOLO pide activar o encender la cámara. ' +
          '• close_camera → Úsala para desactivar y cerrar la cámara en pantalla completa cuando el usuario pida cerrarla o desactivarla. ' +
          '• trigger_haptic_feedback → Úsala para hacer vibrar el teléfono del usuario en momentos clave de peligro o alertas. ' +

          'FLUJO DE SEGURIDAD — REGLA DE ORO: Cuando el usuario mencione cualquier amenaza, DEBES llamar a la herramienta correspondiente EN EL MISMO TURNO, no en el siguiente. Nunca digas "voy a..." sin llamar a la herramienta inmediatamente. ' +
          'QR: Si el usuario menciona "QR", "código QR", "escanear QR", "escanear código QR" o "verificar QR" → llama scan_qr_code AHORA. ' +
          'URL: Si el usuario menciona un enlace → llama analyze_security_url AHORA. ' +
          'Ante cualquier duda, actúa primero y explica después. ' +

          'INTERFAZ GRÁFICA Y DIAGNÓSTICO (MUY IMPORTANTE): ' +
          '1. Cuando analices URL, dominios, IPs, hashes, ficheros o imágenes, NUNCA uses la herramienta "display_content" después. El sistema móvil de hiBOB mostrará automáticamente el panel de métricas de VirusTotal. Tu único trabajo es dar un diagnóstico PROFESIONAL y calmado por voz. ' +
          '2. El sistema te proporcionará siempre el JSON de VirusTotal junto al fichero/imagen. Explica de forma clara el veredicto técnico y justifica el riesgo detectado.'
      });

      client.data.geminiSession = session;
      this.activeSessions.set(uid, {
        session,
        lastClientId: client.id
      });

      this._setupSessionListeners(client, session);
      await session.connect();

    } catch (err: any) {
      this.logger.error(`Error en handleConnection: ${err.message || err}`);
      client.disconnect();
    }
  }

  private _setupSessionListeners(client: Socket, session: GeminiLiveSession) {
    // Limpiamos listeners previos por si es una reconexión
    session.removeAllListeners('audio');
    session.removeAllListeners('transcription');
    session.removeAllListeners('interruption');
    session.removeAllListeners('done');
    session.removeAllListeners('error');
    session.removeAllListeners('tool_call');

    session.on('audio', (audio) => {
      const activeClient = this._getActiveSocket(client);
      if (activeClient) {
        activeClient.emit('audio_chunk', { data: audio.data, mimeType: audio.mimeType || 'audio/pcm' });
      }
    });

    session.on('transcription', (text) => {
      this.logger.log(`[Gemini] Transcripción: ${text}`);
      const activeClient = this._getActiveSocket(client);
      if (activeClient) activeClient.emit('transcription', { text });
    });

    session.on('interruption', () => {
      const activeClient = this._getActiveSocket(client);
      if (activeClient) activeClient.emit('interruption', {});
    });

    session.on('done', () => {
      const activeClient = this._getActiveSocket(client);
      if (activeClient) activeClient.emit('done', {});
    });

    session.on('error', (err) => {
      this.logger.error(`[Gemini] Error en sesión: ${err.message || err}`);
      const activeClient = this._getActiveSocket(client);
      if (activeClient) activeClient.emit('error', { message: err.message || 'Error de IA' });
    });

    session.on('tool_call', async (toolCall) => {
      this.logger.log(`[Gemini] Tool Call: ${JSON.stringify(toolCall)}`);
      const activeClient = this._getActiveSocket(client);
      if (!activeClient) return;

      let pendingClientContent: any[] | null = null;

      const results = await Promise.all(
        toolCall.functionCalls.map(async (fc: any) => {
          // --- OPEN GALLERY ---
          if (fc.name === 'open_gallery') {
            const source = fc.args.source || 'gallery';
            activeClient.emit('command', { action: 'open_gallery', source });
            const payload = await this._waitForFrame(activeClient, 60000);
            const frame = payload?.frameBase64 || payload?.frame;
            if (!frame) return { name: fc.name, id: fc.id, response: { content: 'Cancelado.' } };
            
            const fileName = payload?.fileName || 'imagen.jpg';
            if (source === 'files' || fileName.toLowerCase().endsWith('.apk') || fileName.toLowerCase().endsWith('.pdf')) {
              const vtResult = await this.aiService.executeTool('scan_file_data', { fileBase64: frame, fileName }, activeClient.id);
              const data = JSON.parse(vtResult);
              this._emitVtReport(activeClient, data, fileName);
              return { name: fc.name, id: fc.id, response: { content: `Archivo analizado. Resultado en pantalla.` } };
            }

            session.sendClientContent([
              { text: `Imagen "${fileName}" recibida. Analízala visualmente.` },
              { inlineData: { data: frame, mimeType: 'image/jpeg' } }
            ], true);
            return { name: fc.name, id: fc.id, response: { content: 'Imagen recibida.' } };
          }

          // --- CAPTURE SCREEN / CAMERA VIEW ---
          if (fc.name === 'capture_device_screen' || fc.name === 'describe_camera_view') {
            const source = fc.name === 'capture_device_screen' ? 'screen' : 'camera';
            if (fc.name === 'describe_camera_view' && fc.args.direction) {
              activeClient.emit('command', { action: 'switch_camera', direction: fc.args.direction });
              await new Promise(r => setTimeout(r, 800));
            }
            activeClient.emit('frame_request', { source });
            const payload = await this._waitForFrame(activeClient, 40000);
            const frame = payload?.frameBase64 || payload?.frame;
            if (!frame) return { name: fc.name, id: fc.id, response: { content: 'No se recibió imagen.' } };

            pendingClientContent = [
              { text: `Aquí tienes la captura de ${source}. Analízala.` },
              { inlineData: { data: frame, mimeType: 'image/jpeg' } }
            ];
            return { name: fc.name, id: fc.id, response: { content: 'Imagen en camino.' } };
          }

          // --- SCAN QR CODE (NO BLOQUEANTE) ---
          if (fc.name === 'scan_qr_code') {
            activeClient.emit('frame_request', { source: 'manual_camera' });
            return { name: fc.name, id: fc.id, response: { content: 'Escáner QR abierto. Esperando captura del usuario.' } };
          }

          // --- SCAN FILE (NO BLOQUEANTE) ---
          if (fc.name === 'scan_file') {
            activeClient.emit('command', { action: 'open_gallery', source: 'files' });
            this._processFileInBackground(activeClient, session);
            return { name: fc.name, id: fc.id, response: { content: 'Selector abierto. Procesando en background.' } };
          }

          // --- EJECUCIÓN ESTÁNDAR ---
          if (['analyze_security_url', 'analyze_domain', 'analyze_ip', 'analyze_file_hash', 'web_search', 'check_password_breach'].includes(fc.name)) {
            activeClient.emit('thinking_state', { tool: fc.name, message: this._getThinkingMessage(fc.name) });
          }

          let result = await this.aiService.executeTool(fc.name, fc.args, activeClient.id);

          if (fc.name === 'analyze_security_url') {
            try {
              const data = JSON.parse(result);
              if (!data.error && !data.pending) this._emitVtReport(activeClient, data, data.url ?? fc.args.url);
            } catch (e) {}
          }
          
          // Otros comandos directos
          if (fc.name === 'trigger_qr_capture') activeClient.emit('command', { action: 'trigger_capture' });
          else if (fc.name === 'toggle_flashlight') activeClient.emit('command', { action: 'flashlight', enabled: fc.args.enabled });
          else if (fc.name === 'switch_camera') activeClient.emit('command', { action: 'switch_camera', direction: fc.args.direction });
          else if (fc.name === 'close_camera') activeClient.emit('command', { action: 'close_camera' });
          else if (fc.name === 'trigger_haptic_feedback') activeClient.emit('command', { action: 'vibrate', pattern: fc.args.pattern });
          else if (fc.name === 'display_content') activeClient.emit('display_content', { type: fc.args.contentType || fc.args.type, title: fc.args.title, items: fc.args.items });

          activeClient.emit('thinking_state', null);
          return { name: fc.name, id: fc.id, response: { content: result } };
        })
      );

      session.sendToolResponse(results);
      if (pendingClientContent) {
        await new Promise(r => setTimeout(r, 200));
        session.sendClientContent(pendingClientContent);
      }
    });
  }

  private _getActiveSocket(originalClient: Socket): Socket | null {
    if (originalClient.connected) return originalClient;
    const uid = originalClient.data.uid;
    const sessionData = this.activeSessions.get(uid);
    if (!sessionData) return null;
    const socket = this.server.of('/live').sockets.get(sessionData.lastClientId);
    return socket?.connected ? socket : null;
  }

  handleDisconnect(client: Socket) {
    const uid = client.data.uid;
    if (!uid) return;
    const sessionData = this.activeSessions.get(uid);
    if (!sessionData) return;

    this.logger.warn(`[Disconnect] Cliente ${client.id} desconectado. Esperando 15s para reconexión de UID ${uid}...`);
    sessionData.disconnectTimer = setTimeout(() => {
      this.logger.warn(`[Cleanup] Tiempo agotado para ${uid}. Cerrando sesión.`);
      sessionData.session.close();
      this.activeSessions.delete(uid);
    }, 15000);
  }

  private _emitVtReport(client: Socket, data: any, label: string) {
    const malicious = data.malicious ?? data.positives ?? 0;
    const suspicious = data.suspicious ?? 0;
    const total = data.total ?? (malicious + suspicious + (data.harmless ?? 0) + (data.undetected ?? 0));
    const threatLevel = malicious === 0 ? (suspicious > 0 ? 'suspicious' : 'clean') : (malicious <= 3 ? 'dangerous' : 'critical');
    
    const payload = {
      type: 'vt_report',
      title: malicious > 0 ? 'Amenaza Detectada' : 'Análisis Limpio',
      vtData: { url: label, positives: malicious + suspicious, total, malicious, suspicious, threatLevel, isDanger: malicious > 0, scanDate: new Date().toLocaleString('es-ES') }
    };
    
    // Usar el socket activo actual del usuario
    const activeClient = this._getActiveSocket(client);
    if (activeClient) activeClient.emit('display_content', payload);
  }

  private async _processFileInBackground(client: Socket, session: GeminiLiveSession) {
    const payload = await this._waitForFrame(client, 90000);
    const frame = payload?.frameBase64 || payload?.frame;
    if (!frame) return;
    const fileName = payload?.fileName || 'archivo';
    const vtResult = await this.aiService.executeTool('scan_file_data', { fileBase64: frame, fileName }, client.id);
    const data = JSON.parse(vtResult);
    this._emitVtReport(client, data, fileName);
    session.sendClientContent([{ text: `Archivo "${fileName}" analizado: ${data.positives} motores detectaron amenaza. Da tu diagnóstico.` }], true);
  }

  private _waitForFrame(client: Socket, timeoutMs: number): Promise<FramePayload | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => { client.data.pendingFrameResolve = null; resolve(null); }, timeoutMs);
      client.data.pendingFrameResolve = (p: FramePayload | null) => { clearTimeout(timer); client.data.pendingFrameResolve = null; resolve(p); };
    });
  }

  private _getThinkingMessage(tool: string): string {
    const m = { analyze_security_url: 'Analizando URL...', analyze_domain: 'Verificando dominio...', analyze_ip: 'Chequeando IP...', analyze_file_hash: 'Buscando malware...', web_search: 'Buscando en la web...', check_password_breach: 'Verificando filtraciones...' };
    return m[tool] || 'Procesando...';
  }

  @SubscribeMessage('audio_chunk')
  handleAudioChunk(@MessageBody() payload: AudioChunkPayload, @ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (session && !session.isClosed() && payload?.audioBase64) {
      session.sendAudioFrame(payload.audioBase64, payload.mimeType || 'audio/pcm;rate=16000');
    }
  }

  @SubscribeMessage('heartbeat') handleHeartbeat() { }

  @SubscribeMessage('frame')
  handleFrame(@MessageBody() payload: FramePayload, @ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    const frame = payload?.frameBase64 || payload?.frame;
    if (!session || session.isClosed() || !frame) return;

    if (client.data.pendingFrameResolve) {
      client.data.pendingFrameResolve(payload);
      return;
    }

    if (payload?.prompt === 'qr_scan') {
      this.logger.log(`[QR] Procesando captura manual...`);
      (async () => {
        try {
          const image = await Jimp.fromBuffer(Buffer.from(frame, 'base64'));
          const getBitmapRgba = (bmp: any) => new Uint8ClampedArray(bmp.data.buffer, bmp.data.byteOffset, bmp.data.byteLength);
          let qrData: any = null;
          for (const rot of [0, 90, 180, 270]) {
            const attempt = rot === 0 ? image : image.clone().rotate(rot);
            qrData = jsQR(getBitmapRgba(attempt.bitmap), attempt.bitmap.width, attempt.bitmap.height);
            if (qrData?.data) break;
          }

          if (!qrData?.data) {
            client.emit('frame_request', { source: 'manual_camera' });
            session.sendClientContent([{ text: 'No pude leer el QR. Prueba de nuevo.' }], true);
            return;
          }

          const url = qrData.data.trim();
          const vtRaw = await this.aiService.executeTool('analyze_security_url', { url }, client.id);
          const data = JSON.parse(vtRaw);
          this._emitVtReport(client, data, url);
          session.sendClientContent([{ text: `QR detectado: ${url}. VirusTotal: ${data.positives}/${data.total}. Da diagnóstico.` }], true);
        } catch (e) {
          this.logger.error(`Error QR: ${e.message}`);
        }
      })();
      return;
    }

    session.sendClientContent([{ text: "Vista actual de pantalla." }, { inlineData: { data: frame, mimeType: 'image/jpeg' } }], false);
  }

  @SubscribeMessage('update_location')
  handleUpdateLocation(@MessageBody() p: any, @ConnectedSocket() c: Socket) {
    if (p?.latitude != null) this.locationService.setClientLocation(c.id, p);
  }

  @SubscribeMessage('activity_start') handleActivityStart(@ConnectedSocket() c: Socket) {
    (c.data.geminiSession as GeminiLiveSession)?.sendActivityStart();
  }

  @SubscribeMessage('activity_end') handleActivityEnd(@ConnectedSocket() c: Socket) {
    (c.data.geminiSession as GeminiLiveSession)?.sendActivityEnd();
  }

  @SubscribeMessage('update_settings')
  async handleUpdateSettings(@MessageBody() s: any, @ConnectedSocket() c: Socket) {
    const uid = c.data.uid;
    if (uid) {
      await admin.firestore().collection('users').doc(uid).set(s, { merge: true });
      c.emit('settings_updated', { status: 'ok' });
    }
  }
}
