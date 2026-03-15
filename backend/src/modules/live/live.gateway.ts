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
      
      const userSettingsSnap = await admin.firestore().collection('users').doc(uid).get();
      const userSettings = userSettingsSnap.data() || {};
      const voiceName = userSettings.voiceName || 'Aoede';

      const session = this.aiService.createLiveSession({
        voiceName,
        systemInstruction:
          `Eres hiBOB, un agente de seguridad experto en ciberseguridad. El usuario se llama ${firstName}. ` +
          `Salúdale de forma proactiva y natural. Eres su guardián digital. ` +
          'Tu tono es calmado, profesional y analítico. Detecta el idioma y responde en el mismo. ' +
          'Si preguntan qué haces, usa "display_content" con "features_slider" detallando tus capacidades. ' +
          'HERRAMIENTAS: ' +
          '• analyze_security_url → para URLs. ' +
          '• analyze_domain → para dominios. ' +
          '• analyze_ip → para IPs. ' +
          '• scan_file → para analizar archivos que el usuario elija. ' +
          '• scan_qr_code → Úsala inmediatamente cuando mencionen QR. Abre el escáner. ' +
          '• open_gallery → para ver fotos o capturas del usuario. ' +
          'REGLA: Tras analizar con VirusTotal, hiBOB móvil mostrará el panel automáticamente. Da tu diagnóstico profesional por voz.'
      });

      client.data.geminiSession = session;
      this.activeSessions.set(uid, { session, lastClientId: client.id });

      this._setupSessionListeners(client, session);
      await session.connect();

    } catch (err: any) {
      this.logger.error(`Error en handleConnection: ${err.message || err}`);
      client.disconnect();
    }
  }

  private _setupSessionListeners(client: Socket, session: GeminiLiveSession) {
    session.removeAllListeners('audio');
    session.removeAllListeners('transcription');
    session.removeAllListeners('interruption');
    session.removeAllListeners('done');
    session.removeAllListeners('error');
    session.removeAllListeners('tool_call');

    session.on('audio', (audio) => {
      const activeClient = this._getActiveSocket(client);
      if (activeClient) activeClient.emit('audio_chunk', { data: audio.data, mimeType: audio.mimeType || 'audio/pcm' });
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

      const results = await Promise.all(
        toolCall.functionCalls.map(async (fc: any) => {
          // --- OPEN GALLERY / FILES ---
          if (fc.name === 'open_gallery' || fc.name === 'scan_file') {
            const source = fc.name === 'scan_file' ? 'files' : (fc.args.source || 'gallery');
            activeClient.emit('command', { action: 'open_gallery', source });
            const payload = await this._waitForFrame(activeClient, 60000);
            const frame = payload?.frameBase64 || payload?.frame;
            if (!frame) return { name: fc.name, id: fc.id, response: { content: 'Operación cancelada por el usuario.' } };
            
            const fileName = payload?.fileName || 'archivo.dat';
            if (source === 'files' || fileName.toLowerCase().endsWith('.apk') || fileName.toLowerCase().endsWith('.pdf')) {
              const vtResult = await this.aiService.executeTool('scan_file_data', { fileBase64: frame, fileName }, activeClient.id);
              const data = JSON.parse(vtResult);
              this._emitVtReport(activeClient, data, fileName);
              return { name: fc.name, id: fc.id, response: { content: `Archivo analizado. Resultado en pantalla.` } };
            }
            session.sendClientContent([{ inlineData: { data: frame, mimeType: 'image/jpeg' } }], true);
            return { name: fc.name, id: fc.id, response: { content: 'Imagen recibida y en análisis visual.' } };
          }

          // --- SCAN QR CODE (NO BLOQUEANTE) ---
          if (fc.name === 'scan_qr_code') {
            activeClient.emit('frame_request', { source: 'manual_camera' });
            return { name: fc.name, id: fc.id, response: { content: 'Escáner QR abierto. Esperando que el usuario capture el código.' } };
          }

          // --- HERRAMIENTAS DE SEGURIDAD ---
          if (['analyze_security_url', 'analyze_domain', 'analyze_ip'].includes(fc.name)) {
            activeClient.emit('thinking_state', { tool: fc.name, message: 'Consultando bases de datos de amenazas...' });
          }

          let result = await this.aiService.executeTool(fc.name, fc.args, activeClient.id);

          try {
            const data = JSON.parse(result);
            if (fc.name === 'analyze_security_url' && !data.error) this._emitVtReport(activeClient, data, data.url ?? fc.args.url);
            if (fc.name === 'analyze_ip' && !data.error) activeClient.emit('display_content', { type: 'ip_report', title: 'Análisis de IP', ipData: data });
            if (fc.name === 'analyze_domain' && !data.error) activeClient.emit('display_content', { type: 'domain_report', title: 'Análisis de Dominio', domainData: data });
          } catch (e) {}

          // --- COMANDOS DISPOSITIVO ---
          if (fc.name === 'trigger_qr_capture') activeClient.emit('command', { action: 'trigger_capture' });
          else if (fc.name === 'switch_camera') activeClient.emit('command', { action: 'switch_camera', direction: fc.args.direction });
          else if (fc.name === 'close_camera') activeClient.emit('command', { action: 'close_camera' });
          else if (fc.name === 'display_content') activeClient.emit('display_content', { type: fc.args.contentType || fc.args.type, title: fc.args.title, items: fc.args.items });

          activeClient.emit('thinking_state', null);
          return { name: fc.name, id: fc.id, response: { content: result } };
        })
      );
      session.sendToolResponse(results);
    });
  }

  private _getActiveSocket(originalClient: Socket): Socket | null {
    if (originalClient.connected) return originalClient;
    const uid = originalClient.data.uid;
    const sessionData = this.activeSessions.get(uid);
    if (!sessionData) return null;
    const socket = this.server.of('/live').sockets.get(sessionData.lastClientId);
    return (socket && socket.connected) ? socket : null;
  }

  handleDisconnect(client: Socket) {
    const uid = client.data.uid;
    if (!uid) return;
    const sessionData = this.activeSessions.get(uid);
    if (!sessionData) return;

    this.logger.warn(`[Disconnect] Cliente ${client.id} desconectado. Esperando 15s reconexión...`);
    sessionData.disconnectTimer = setTimeout(() => {
      this.logger.warn(`[Cleanup] Sesión de usuario ${uid} cerrada por inactividad.`);
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
      title: malicious > 0 ? 'Amenaza Detectada' : (suspicious > 0 ? 'Actividad Sospechosa' : 'Análisis Limpio'),
      vtData: { url: label, positives: malicious + suspicious, total, malicious, suspicious, threatLevel, isDanger: malicious > 0, scanDate: new Date().toLocaleString('es-ES') }
    };
    const activeClient = this._getActiveSocket(client);
    if (activeClient) activeClient.emit('display_content', payload);
  }

  private _waitForFrame(client: Socket, timeoutMs: number): Promise<FramePayload | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => { client.data.pendingFrameResolve = null; resolve(null); }, timeoutMs);
      client.data.pendingFrameResolve = (p: FramePayload | null) => { clearTimeout(timer); client.data.pendingFrameResolve = null; resolve(p); };
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

    // Si hay una herramienta esperando este frame (Captura de pantalla, Galería, etc)
    if (client.data.pendingFrameResolve) {
      client.data.pendingFrameResolve(payload);
      return;
    }

    // Procesamiento de QR manual (siempre activo para frames con tag qr_scan)
    if (payload?.prompt === 'qr_scan') {
      this.logger.log(`[QR] Procesando captura manual en ${client.id}...`);
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
            session.sendClientContent([{ text: 'No he podido leer el código QR. Por favor, céntralo bien y pulsa el botón de captura de nuevo.' }], true);
            return;
          }

          const url = qrData.data.trim();
          this.logger.log(`[QR] URL detectada: ${url}. Analizando...`);
          
          client.emit('display_content', { type: 'qr_scan', title: 'Analizando QR...', items: [{ id: 'qr_progress', title: url, description: 'Verificando seguridad...' }] });

          const vtRaw = await this.aiService.executeTool('analyze_security_url', { url }, client.id);
          const data = JSON.parse(vtRaw);
          
          this._emitVtReport(client, data, url);
          
          // Re-vincular a la sesión actual (por si hubo reconexión)
          const currentSession = client.data.geminiSession as GeminiLiveSession;
          if (currentSession && !currentSession.isClosed()) {
            const isSafe = data.positives === 0;
            if (isSafe) client.emit('command', { action: 'open_url', url });
            currentSession.sendClientContent([{ text: `Análisis de QR finalizado para ${url}. VirusTotal detectó ${data.positives} amenazas. Da tu diagnóstico por voz.` }], true);
          }
        } catch (e) { this.logger.error(`Error QR: ${e.message}`); }
      })();
      return;
    }

    // Captura proactiva para visión continua
    session.sendClientContent([{ inlineData: { data: frame, mimeType: 'image/jpeg' } }], false);
  }

  @SubscribeMessage('heartbeat') handleHeartbeat() { }
  @SubscribeMessage('update_location') handleUpdateLocation(@MessageBody() p: any, @ConnectedSocket() c: Socket) { if (p?.latitude != null) this.locationService.setClientLocation(c.id, p); }
  @SubscribeMessage('activity_start') handleActivityStart(@ConnectedSocket() c: Socket) { (c.data.geminiSession as GeminiLiveSession)?.sendActivityStart(); }
  @SubscribeMessage('activity_end') handleActivityEnd(@ConnectedSocket() c: Socket) { (c.data.geminiSession as GeminiLiveSession)?.sendActivityEnd(); }
  @SubscribeMessage('update_settings') async handleUpdateSettings(@MessageBody() s: any, @ConnectedSocket() c: Socket) {
    if (c.data.uid) await admin.firestore().collection('users').doc(c.data.uid).set(s, { merge: true });
  }
}
