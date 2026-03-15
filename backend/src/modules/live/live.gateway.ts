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
      client.data.uid = decoded.uid;

      // Obtener nombre del usuario desde Firebase Auth y usar solo el primer nombre
      const userRecord = await admin.auth().getUser(decoded.uid);
      const fullDisplayName = userRecord.displayName || userRecord.email?.split('@')[0] || 'amigo';
      const firstName = fullDisplayName.trim().split(' ')[0];
      this.logger.log(`Cliente conectado: ${client.id} (uid=${decoded.uid}, name=${fullDisplayName}, usedName=${firstName})`);
      
      // Obtener preferencias del usuario desde Firestore
      const userSettingsSnap = await admin.firestore().collection('users').doc(decoded.uid).get();
      const userSettings = userSettingsSnap.data() || {};
      const voiceName = userSettings.voiceName || 'Puck';
      this.logger.log(`Preferencias de usuario: voiceName=${voiceName}`);

      const uid = decoded.uid;

      // ── Reconexión transparente: reutilizar sesión Gemini existente si la hay ──
      const existingSessionData = this.activeSessions.get(uid);
      let session: GeminiLiveSession;
      let isReconnection = false;

      if (existingSessionData && !existingSessionData.session.isClosed()) {
        // Cancelar el timer de cierre diferido
        if (existingSessionData.disconnectTimer) {
          clearTimeout(existingSessionData.disconnectTimer);
          existingSessionData.disconnectTimer = undefined;
        }
        // Reutilizar la sesión existente
        session = existingSessionData.session;
        const previousClientId = existingSessionData.lastClientId;
        existingSessionData.lastClientId = client.id;
        isReconnection = true;
        this.logger.log(`[Reconexión] UID ${uid} reconectado. Reutilizando sesión Gemini existente (socket anterior: ${previousClientId} → nuevo: ${client.id})`);
      } else {
        // Crear nueva sesión
        session = this.aiService.createLiveSession({
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

        // Guardar la nueva sesión en el mapa persistente
        this.activeSessions.set(uid, { session, lastClientId: client.id });
      }

      client.data.geminiSession = session;

      // Reasignar listeners al nuevo socket (en reconexión, los anteriores apuntaban al socket viejo)
      session.removeAllListeners('audio');
      session.removeAllListeners('transcription');
      session.removeAllListeners('interruption');
      session.removeAllListeners('done');
      session.removeAllListeners('error');
      session.removeAllListeners('close');

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
        if (client.connected) {
           client.emit('error', { message: 'La conexión con el núcleo de IA se ha cerrado inesperadamente.' });
        }
      });

      // En reconexión, NO volvemos a hacer connect() — la sesión ya está activa
      // Solo reasignamos el listener de tool_call al nuevo socket
      if (isReconnection) {
        session.removeAllListeners('tool_call');
      }

      session.on('tool_call', async (toolCall) => {
        this.logger.log(`[Gemini] Tool Call: ${JSON.stringify(toolCall)}`);
        // pendingClientContent: contenido a enviar DESPUÉS del sendToolResponse (para imágenes de galería)
        let pendingClientContent: any[] | null = null;

        const results = await Promise.all(
          toolCall.functionCalls.map(async (fc: any) => {
            // open_gallery: flujo para obtener imagen de la galería
            if (fc.name === 'open_gallery') {
              const source = fc.args.source || 'gallery';
              this.logger.log(`[Herramienta] Solicitando ${source} para ${client.id}...`);
              client.emit('command', { action: 'open_gallery', source });
              
              const payload = await this._waitForFrame(client, 60000);
              const frame = payload?.frameBase64 || payload?.frame;

              if (!frame) {
                return { name: fc.name, id: fc.id, response: { content: 'El usuario canceló la selección.' } };
              }

              const fileName = payload?.fileName || (source === 'gallery' ? 'imagen.jpg' : 'archivo.dat');

              // --- FLUJO A: ARCHIVOS (PDF, APK, etc.) ---
              if (source === 'files' || fileName.toLowerCase().endsWith('.apk') || fileName.toLowerCase().endsWith('.pdf')) {
                this.logger.log(`[Fichero] Analizando archivo malicioso: ${fileName}`);
                const vtResult = await this.aiService.executeTool('scan_file_data', { fileBase64: frame, fileName }, client.id);
                try {
                  const data = JSON.parse(vtResult);
                  if (data.error || data.pending) return { name: fc.name, id: fc.id, response: { content: 'Análisis de archivo pendiente o fallido.' } };
                  this._emitVtReport(client, data, fileName);
                  return { name: fc.name, id: fc.id, response: { content: `Archivo analizado: ${data.malicious} positivos. Resultado en pantalla.` } };
                } catch { return { name: fc.name, id: fc.id, response: { content: 'Error en análisis de archivo.' } }; }
              }

              // --- FLUJO B: IMÁGENES (Búsqueda de Phishing/URLs) ---
              this.logger.log(`[Visión] Enviando imagen a Gemini para extraer amenazas visuales...`);
              client.emit('display_content', {
                type: 'file_scan',
                title: 'Analizando Imagen',
                items: [{ id: 'scan_progress', title: fileName, description: 'Buscando URLs y amenazas visuales...' }]
              });

              // Enviamos la imagen como contenido del cliente para que Gemini la procese
              session.sendClientContent([
                { text: `El usuario ha seleccionado esta imagen ("${fileName}"). Búscala visualmente en busca de URLs, dominios, códigos QR o mensajes sospechosos. Si encuentras una URL, analízala con la herramienta pertinente. Si no hay nada sospechoso, informa al usuario y dale un consejo de seguridad.` },
                { inlineData: { data: frame, mimeType: 'image/jpeg' } }
              ], true);

              return { name: fc.name, id: fc.id, response: { content: 'Imagen recibida. Estoy analizándola visualmente ahora mismo.' } };
            }

            // Manejo de herramientas visuales reactivas (BLOQUEANTES)
            if (fc.name === 'capture_device_screen' || fc.name === 'describe_camera_view') {
              const source = fc.name === 'capture_device_screen' ? 'screen' : 'camera';
              
              if (fc.name === 'describe_camera_view' && fc.args.direction) {
                client.emit('command', { action: 'switch_camera', direction: fc.args.direction });
                await new Promise(resolve => setTimeout(resolve, 800)); // Esperamos a que la cámara cambie de lente
              }

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

              // MOSTRAR EN PANTALLA (UI) - Solo para pantalla, porque la cámara ya se muestra en grande de fondo
              if (source === 'screen') {
                client.emit('display_content', {
                  type: 'detail',
                  title: `Analizando Captura`,
                  items: [{
                      id: 'analysis_frame',
                      title: 'Imagen Capturada',
                      description: 'Procesando imagen con IA (esperando respuesta visual)...',
                      imageUrl: `data:image/jpeg;base64,${frame}`
                  }]
                });

                pendingClientContent = [
                  { text: `Aquí tienes la imagen solicitada (screen). Analízala cuidadosamente. IMPORTANTE: Tras procesarla, usa OBLIGATORIAMENTE la herramienta "display_content" para actualizar la pantalla con un resumen de tus hallazgos.` },
                  { inlineData: { data: frame, mimeType: 'image/jpeg' } }
                ];
              } else {
                pendingClientContent = [
                  { text: `Aquí tienes la captura que has tomado de tu cámara. Analízala visualmente AHORA. IMPORTANTE: NO uses "display_content" (la solaparía), simplemente responde por voz detallando exactamente lo que ves en la imagen.` },
                  { inlineData: { data: frame, mimeType: 'image/jpeg' } }
                ];
              }

              return { 
                name: fc.name, 
                id: fc.id, 
                response: { 
                  content: source === 'screen' 
                    ? 'Captura en camino. NO hables hasta que recibas la imagen en el próximo turno.' 
                    : 'Captura de cámara en camino. NO hables ni inventes nada hasta que recibas la imagen en el próximo mensaje.' 
                } 
              };
            }

            // ── QR Code: flujo NO BLOQUEANTE para evitar timeouts y desconexiones ──
            if (fc.name === 'scan_qr_code') {
              this.logger.log(`[Herramienta] Solicitando QR para ${client.id}...`);
              // Abrimos visor en el móvil
              client.emit('frame_request', { source: 'manual_camera' });

              return {
                name: fc.name,
                id: fc.id,
                response: { content: 'Escáner QR abierto en el dispositivo del usuario. Dile al usuario que enfoque el código y pulse el botón de captura para analizarlo. No digas nada más hasta recibir el resultado.' }
              };
            }

            // ── Scan File: solicita archivo y procesa en background (como scan_qr_code) ──
            // Motivo: el file picker manda la app a background → el WebSocket puede reconectarse
            // con un nuevo socket ID → el _waitForFrame del socket original nunca se resuelve.
            // Solución: respondemos inmediatamente a Gemini y procesamos el fichero en background.
            if (fc.name === 'scan_file') {
              this.logger.log(`[Herramienta] Solicitando fichero para VirusTotal para ${client.id}...`);
              client.emit('command', { action: 'open_gallery', source: 'files' });

              // Procesamos en background para no bloquear el tool response a Gemini
              this._processFileInBackground(client, session);

              return {
                name: fc.name,
                id: fc.id,
                response: { content: 'Selector de ficheros abierto. Esperando que el usuario elija el archivo. Dile que seleccione el fichero que desea analizar y confirme. No digas nada más hasta recibir el resultado.' }
              };
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
              } catch (e: any) {
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
            if (fc.name === 'trigger_qr_capture') {
              client.emit('command', { action: 'trigger_capture' });
            } else if (fc.name === 'toggle_flashlight') {
              client.emit('command', { action: 'flashlight', enabled: fc.args.enabled });
            } else if (fc.name === 'switch_camera') {
              client.emit('command', { action: 'switch_camera', direction: fc.args.direction });
            } else if (fc.name === 'close_camera') {
              client.emit('command', { action: 'close_camera' });
            } else if (fc.name === 'trigger_haptic_feedback') {
              client.emit('command', { action: 'vibrate', pattern: fc.args.pattern });
            } else if (fc.name === 'display_content') {
              // Mantenemos 'type' para el cliente de Flutter por compatibilidad, pero lo extraemos de 'contentType'
              client.emit('display_content', { 
                type: fc.args.contentType || fc.args.type, 
                title: fc.args.title, 
                items: fc.args.items 
              });
            }

            // Limpiar el skeleton de "pensando" siempre que la herramienta termine
            client.emit('thinking_state', null);

            return { name: fc.name, id: fc.id, response: { content: result } };
          }),
        );
        // Delay para que el display_content llegue y se renderice en el cliente
        // ANTES de que Gemini procese el tool response y empiece a generar audio
        const hasDisplayContent = results.some(r =>
          ['analyze_security_url','analyze_ip','analyze_domain','analyze_file_hash',
           'scan_file','check_password_breach','generate_password'].includes((r as any).name)
        );
        if (hasDisplayContent) {
          await new Promise(resolve => setTimeout(resolve, 350));
        }

        session.sendToolResponse(results);

        // Enviar imagen DESPUÉS del tool response para que Gemini la reciba en el turno correcto
        if (pendingClientContent) {
          await new Promise(resolve => setTimeout(resolve, 150));
          session.sendClientContent(pendingClientContent);
        }
      });

      // Conectar solo si es una sesión nueva (en reconexión ya está conectada)
      if (!isReconnection) {
        await session.connect();
      }

    } catch (err: any) {
      this.logger.error(`Error en handleConnection: ${err.message || err}`);
      client.disconnect();
    }
  }

  handleDisconnect(client: Socket) {
    const uid = client.data.uid;
    if (!uid) {
      this.logger.log(`Cliente anónimo desconectado: ${client.id}`);
      return;
    }

    const sessionData = this.activeSessions.get(uid);
    if (!sessionData) return;

    this.logger.warn(`[Disconnect] Cliente ${client.id} de usuario ${uid} desconectado. Iniciando espera de 15s para reconexión...`);

    // Iniciamos un timer de 15 segundos antes de borrar la sesión de hiBOB definitivamente
    sessionData.disconnectTimer = setTimeout(() => {
      this.logger.warn(`[Cleanup] Tiempo agotado para usuario ${uid}. Cerrando sesión de Gemini definitivamente.`);
      sessionData?.session.close();
      this.activeSessions.delete(uid);
      this.locationService.removeClientLocation(client.id);
    }, 15000);
  }

  private _emitVtReport(client: Socket, data: any, label: string) {
    const malicious = data.malicious ?? data.positives ?? 0;
    const suspicious = data.suspicious ?? 0;
    const harmless = data.harmless ?? 0;
    const undetected = data.undetected ?? 0;
    const total = data.total ?? (malicious + suspicious + harmless + undetected);
    
    const isDanger = malicious > 0;
    const threatLevel = malicious === 0 ? (suspicious > 0 ? 'suspicious' : 'clean')
      : malicious <= 3 ? 'dangerous'
      : 'critical';

    const scanDate = new Date().toLocaleString('es-ES', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
    
    this.logger.log(`[VT-Report] Preparando reporte para ${client.id} (uid: ${client.data.uid}): ${malicious}/${total} positivos (${threatLevel})`);

    const payload = {
      type: 'vt_report',
      title: isDanger ? 'Amenaza Detectada' : (threatLevel === 'suspicious' ? 'Actividad Sospechosa' : 'Análisis Limpio'),
      vtData: {
        url: label,
        positives: malicious + suspicious,
        total: total,
        harmless: harmless,
        suspicious: suspicious,
        malicious: malicious,
        undetected: undetected,
        fileName: data.fileName,
        fileType: data.fileType,
        fileSize: data.fileSize,
        threatLevel,
        isDanger,
        scanDate,
      },
    };

    // Enviamos al usuario (resiliente a reconexiones)
    this._emitToUser(client, 'display_content', payload);
  }

  /**
   * Envía un evento al socket proporcionado o, si se ha desconectado, 
   * busca el socket activo actual del mismo usuario (por UID).
   */
  private async _emitToUser(originalClient: Socket, event: string, payload: any) {
    // Si el socket original sigue conectado, emitimos directamente
    if (originalClient.connected) {
      originalClient.emit(event, payload);
      return;
    }

    const uid = originalClient.data.uid;
    if (!uid) {
      this.logger.warn(`[EmitToUser] Socket ${originalClient.id} desconectado y sin UID. No se puede reencaminar ${event}.`);
      return;
    }

    this.logger.log(`[EmitToUser] Socket ${originalClient.id} desconectado. Esperando breve reconexión de UID ${uid}...`);
    
    // Pequeña espera por si el cliente está reconectando justo ahora
    await new Promise(resolve => setTimeout(resolve, 1500));

    // Buscamos en todos los sockets del namespace 'live' aquel que tenga el mismo UID
    const activeSockets = Array.from(this.server.of('/live').sockets.values());
    const newClient = activeSockets.find(s => s.data.uid === uid && s.id !== originalClient.id);

    if (newClient) {
      this.logger.log(`[EmitToUser] Reencaminando evento ${event} de ${originalClient.id} -> ${newClient.id} (reconexión exitosa)`);
      newClient.emit(event, payload);
    } else {
      // Intento final en el namespace raíz por si acaso
      const rootSockets = Array.from(this.server.sockets.sockets.values());
      const rootClient = rootSockets.find(s => s.data.uid === uid);
      
      if (rootClient) {
        this.logger.log(`[EmitToUser] Reencaminando evento ${event} a socket en namespace raíz: ${rootClient.id}`);
        rootClient.emit(event, payload);
      } else {
        this.logger.warn(`[EmitToUser] No se encontró socket activo para UID ${uid} tras espera. Evento ${event} perdido.`);
      }
    }
  }

  private _processFileInBackground(client: Socket, session: GeminiLiveSession): void {
    this.logger.log(`[File] Iniciando espera de fichero para cliente ${client.id}...`);
    this._waitForFrame(client, 90000).then(async (payload) => {
      const fileFrame = payload?.frameBase64 || payload?.frame;
      if (!fileFrame) {
        this.logger.warn(`[File] No se recibió fichero para el cliente ${client.id} (timeout o cancelación)`);
        session.sendClientContent([{ text: 'El usuario no seleccionó ningún fichero o canceló la operación. Informa al usuario brevemente.' }], true);
        return;
      }

      const fileName = payload?.fileName || 'archivo';
      this.logger.log(`[File] Fichero recibido: "${fileName}" (${fileFrame.length} chars). Subiendo a VirusTotal...`);

      client.emit('display_content', {
        type: 'file_scan',
        title: 'Analizando archivo...',
        items: [{ id: 'scan_progress', title: fileName, description: 'Subiendo a VirusTotal...' }],
      });

      try {
        const vtResult = await this.aiService.executeTool('scan_file_data', { fileBase64: fileFrame, fileName }, client.id);
        client.emit('display_content', {
          type: 'file_scan',
          title: 'Analizando archivo...',
          items: [{ id: 'scan_progress', title: fileName, description: 'Generando diagnóstico...' }],
        });
        const data = JSON.parse(vtResult);
        this._emitVtReport(client, data, fileName);
        await new Promise(resolve => setTimeout(resolve, 300));
        this.logger.log(`[File] Análisis de "${fileName}" completado. ${data.positives}/${data.total} amenazas detectadas.`);
        session.sendClientContent([{
          text: `Análisis de archivo finalizado.
Nombre: "${fileName}"
Resultado VirusTotal: ${data.positives ?? 0}/${data.total ?? 0} motores detectaron amenaza.
El panel de métricas ya se muestra en pantalla.
Instrucción: Da tu diagnóstico profesional por voz en 2-3 frases. NUNCA uses la herramienta "display_content" porque ya se muestra el panel automáticamente.`
        }], true);
      } catch (e: any) {
        this.logger.error(`[File] Error procesando fichero para ${client.id}: ${e.message}`);
        session.sendClientContent([{ text: `Error técnico al analizar el archivo "${fileName}": ${e.message || 'Error desconocido'}. Informa al usuario y discúlpate.` }], true);
      }
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

  @SubscribeMessage('heartbeat')
  handleHeartbeat(@ConnectedSocket() client: Socket) {
    // Mantiene la conexión Cloud Run activa durante esperas largas (ej. visor QR).
    this.logger.debug(`[Heartbeat] ${client.id}`);
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

    // PRIORIDAD 2a: El usuario envió una captura manual de QR.
    // Este path cubre reconexiones donde el socket original perdió la espera pendiente.
    if (payload?.prompt === 'qr_scan') {
      this.logger.log(`[QR] Captura manual recibida en ${client.id}. Analizando QR...`);

      (async () => {
        try {
          const imageBuffer = Buffer.from(frame, 'base64');
          const image = await Jimp.fromBuffer(imageBuffer);
          this.logger.log(`[QR] Imagen manual cargada: ${image.bitmap.width}x${image.bitmap.height}px`);

          const getBitmapRgba = (bmp: { data: Buffer; width: number; height: number }) =>
            new Uint8ClampedArray(bmp.data.buffer, bmp.data.byteOffset, bmp.data.byteLength);

          const prepareImage = (src: typeof image): typeof image => {
            const clone = src.clone();
            const { width, height } = clone.bitmap;
            const minDim = Math.min(width, height);
            const maxDim = Math.max(width, height);
            if (maxDim < 400) { clone.scale(Math.ceil(400 / maxDim)); }
            else if (minDim > 1200) { clone.scaleToFit({ w: 1200, h: 1200 }); }
            return clone;
          };

          const strategies = [
            prepareImage(image),
            prepareImage(image).contrast(1.0),
            prepareImage(image).greyscale().contrast(0.5).threshold({ max: 128 }),
          ];
          const rotations = [0, 90, 180, 270];

          let qrData: ReturnType<typeof jsQR> = null;
          outerLoop:
          for (const strategy of strategies) {
            for (const rotation of rotations) {
              const attempt = rotation === 0 ? strategy.clone() : strategy.clone().rotate(rotation);
              const bmp = attempt.bitmap;
              const rgba = getBitmapRgba(bmp);
              qrData = jsQR(rgba, bmp.width, bmp.height);
              if (qrData?.data) {
                this.logger.log(`[QR] QR manual decodificado con éxito (rotación ${rotation}°)`);
                break outerLoop;
              }
            }
          }

          if (!qrData?.data) {
            client.emit('frame_request', { source: 'manual_camera' });
            // Intentamos enviar feedback a la sesión si existe
            if (session && !session.isClosed()) {
              session.sendClientContent([{
                text: 'No he podido leer el código QR en la última captura. Pide al usuario que lo centre mejor en el recuadro y que diga "listo" o pulse capturar para intentarlo de nuevo.'
              }], true);
            }
            return;
          }

          const url = qrData.data.trim();
          this.logger.log(`[QR] URL detectada: "${url}". Analizando...`);

          // Mostrar overlay de progreso en el móvil inmediatamente
          client.emit('display_content', {
            type: 'qr_scan',
            title: 'Analizando URL...',
            items: [{ id: 'qr_progress', title: url, description: 'Consultando VirusTotal y reputación web...' }],
          });

          // Analizar URL con VirusTotal (Herramienta directa del AiService)
          const vtRaw = await this.aiService.executeTool('analyze_security_url', { url }, client.id);
          const data = JSON.parse(vtRaw);
          if (data.error) throw new Error(data.error);

          this.logger.log(`[QR] Análisis completado para ${url}: ${data.positives} positivos`);
          
          // Emitir reporte visual de VirusTotal
          this._emitVtReport(client, data, url);

          const isSafe = data.positives === 0;
          if (isSafe) {
            client.emit('command', { action: 'open_url', url });
          }

          // SIEMPRE forzamos la respuesta de hiBOB, incluso si la sesión es nueva
          // Esperamos un momento para que Gemini esté listo tras la reconexión
          await new Promise(resolve => setTimeout(resolve, 800));
          
          const currentSession = client.data.geminiSession as GeminiLiveSession;
          if (currentSession && !currentSession.isClosed()) {
            currentSession.sendClientContent([{
              text: `Análisis de código QR finalizado.
URL detectada: "${url}"
Resultado VirusTotal: ${data.positives}/${data.total} motores detectaron amenazas.
Contexto de Internet: ${data.internet_context || 'No se encontró información adicional.'}
Acción realizada: ${isSafe ? 'Se ha abierto la URL automáticamente.' : 'Bloqueado por seguridad.'}

Instrucción: Da tu diagnóstico profesional por voz basándote en estos datos. Si VirusTotal es 0 pero el contexto de internet menciona estafas o phishing, advierte al usuario seriamente y no digas que es seguro.`
            }], true);
          }
        } catch (err: any) {
          this.logger.error(`Error procesando captura de QR: ${err.message || err}`);
          if (session && !session.isClosed()) {
            session.sendClientContent([{ text: 'Hubo un error técnico al analizar el código QR. Informa al usuario y pide una nueva captura.' }], true);
          }
        }
      })();
      return;
    }

    // PRIORIDAD 2b: El usuario envió una IMAGEN manualmente (botón UI con prompt 'analyze_image').
    if (payload?.prompt === 'analyze_image') {
      const fileName = payload?.fileName || 'Imagen_Galeria.jpg';
      this.logger.log(`[Visión] Imagen manual recibida para ${fileName} en ${client.id}`);
      
      this.aiService.executeTool('scan_file_data', { fileBase64: frame, fileName }, client.id)
        .then((vtResult) => {
          try {
            const data = JSON.parse(vtResult);
            this._emitVtReport(client, data, fileName);
            session.sendClientContent([
              { text: `El usuario acaba de enviarte manualmente esta imagen: "${fileName}". Resultados de VirusTotal: ${data.positives}/${data.total} motores detectaron amenaza. Obsérvala visualmente y da tu diagnóstico profesional por voz unificando VirusTotal y el contenido visual. NUNCA uses la herramienta "display_content", porque el panel de métricas de seguridad ya se muestra en pantalla automáticamente.` },
              { inlineData: { data: frame, mimeType: 'image/jpeg' } }
            ], true);
          } catch (e) {
            this.logger.error(`Error parseando resultado de VirusTotal para ${fileName}: ${e}`);
          }
        })
        .catch((err) => {
          this.logger.error(`Error procesando imagen manual ${fileName}: ${err}`);
        });
      return;
    }

    // PRIORIDAD 2c: El usuario envió un FICHERO manualmente (botón UI con fileName sin prompt).
    // Este path también cubre el caso donde scan_file reconectó y el fichero llega en nueva sesión.
    if (payload?.fileName) {
      const fileName = payload.fileName;
      this.logger.log(`[Fichero] Análisis de fichero manual recibido: "${fileName}" en ${client.id}`);

      client.emit('display_content', {
        type: 'file_scan',
        title: 'Analizando archivo...',
        items: [{ id: 'scan_progress', title: fileName, description: 'Subiendo a VirusTotal...' }],
      });

      this.aiService.executeTool('scan_file_data', { fileBase64: frame, fileName }, client.id)
        .then(async (vtResult) => {
          try {
            const data = JSON.parse(vtResult);
            this._emitVtReport(client, data, fileName);
            await new Promise(resolve => setTimeout(resolve, 300));
            session.sendClientContent([{
              text: `El usuario acaba de enviarte manualmente este fichero: "${fileName}".
Resultados de VirusTotal: ${data.positives ?? 0}/${data.total ?? 0} motores detectaron amenaza.
El panel de métricas ya se muestra en pantalla.
Instrucción: Da tu diagnóstico profesional por voz en 2-3 frases. NUNCA uses la herramienta "display_content" porque ya se muestra el panel automáticamente.`
            }], true);
          } catch (e) {
            this.logger.error(`Error parseando resultado de VirusTotal para fichero ${fileName}: ${e}`);
          }
        })
        .catch((err) => {
          this.logger.error(`Error procesando fichero manual ${fileName}: ${err}`);
        });
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

  @SubscribeMessage('activity_start')
  handleActivityStart(@ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (session && !session.isClosed()) {
      this.logger.log(`[VAD Manual] Recibida señal de actividad del cliente ${client.id} - Interrumpiendo Gemini...`);
      session.sendActivityStart();
    }
  }

  @SubscribeMessage('activity_end')
  handleActivityEnd(@ConnectedSocket() client: Socket) {
    const session = client.data.geminiSession as GeminiLiveSession;
    if (session && !session.isClosed()) {
      this.logger.log(`[VAD Manual] Recibida señal de fin de actividad del cliente ${client.id}`);
      session.sendActivityEnd();
    }
  }

  @SubscribeMessage('update_settings')
  async handleUpdateSettings(@MessageBody() settings: any, @ConnectedSocket() client: Socket) {
    const uid = client.data.uid;
    if (!uid) return;
    
    this.logger.log(`Actualizando ajustes para usuario ${uid}: ${JSON.stringify(settings)}`);
    await admin.firestore().collection('users').doc(uid).set(settings, { merge: true });
    client.emit('settings_updated', { status: 'ok' });
  }
}
