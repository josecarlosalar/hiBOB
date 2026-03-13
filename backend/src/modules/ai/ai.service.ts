import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  GoogleGenAI,
  Content,
  Part,
  Tool,
  FunctionDeclaration,
  Type,
  Modality,
} from '@google/genai';
import { BraveSearchService } from '../tools/brave-search.service';
import { LocationService } from '../tools/location.service';
import { VirusTotalService } from '../tools/virustotal.service';
import { HibpService } from '../tools/hibp.service';
import { EventEmitter } from 'events';

// ─── Herramientas ────────────────────────────────────────────────────────────

const WEB_SEARCH_FUNCTION: FunctionDeclaration = {
  name: 'web_search',
  description: 'Busca información actualizada en internet usando Brave Search.',
  parameters: { type: Type.OBJECT, properties: { query: { type: Type.STRING, description: 'La consulta de búsqueda' } }, required: ['query'] },
};

const GET_LOCATION_FUNCTION: FunctionDeclaration = {
  name: 'get_current_location',
  description: 'Obtiene la ubicación actual del usuario.',
  parameters: { type: Type.OBJECT, properties: {} },
};

const DESCRIBE_VISION_FUNCTION: FunctionDeclaration = {
  name: 'describe_camera_view',
  description: 'Mira y analiza lo que hay frente a la cámara (trasera o frontal). Usa esta herramienta automáticamente cuando el usuario te pida ver algo de su entorno, analizar un objeto físico, o mirarle a él.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      direction: {
        type: Type.STRING,
        enum: ['front', 'back'],
        description: 'La lente a usar. Usa "back" para ver objetos externos/entorno y "front" para ver al usuario frontalmente. Si no estás seguro, omite este parámetro.'
      }
    }
  },
};

const TOGGLE_FLASHLIGHT_FUNCTION: FunctionDeclaration = {
  name: 'toggle_flashlight',
  description: 'Enciende o apaga la linterna del dispositivo.',
  parameters: { type: Type.OBJECT, properties: { enabled: { type: Type.BOOLEAN, description: 'True para encender' } }, required: ['enabled'] },
};

const TRIGGER_HAPTIC_FEEDBACK_FUNCTION: FunctionDeclaration = {
  name: 'trigger_haptic_feedback',
  description: 'Hace que el teléfono vibre.',
  parameters: { type: Type.OBJECT, properties: { pattern: { type: Type.STRING, enum: ['success', 'warning', 'error', 'heavy'] } }, required: ['pattern'] },
};

const SWITCH_CAMERA_FUNCTION: FunctionDeclaration = {
  name: 'switch_camera',
  description: 'Cambia entre cámara frontal y trasera.',
  parameters: { type: Type.OBJECT, properties: { direction: { type: Type.STRING, enum: ['front', 'back'] } }, required: ['direction'] },
};

const DISPLAY_CONTENT_FUNCTION: FunctionDeclaration = {
  name: 'display_content',
  description: 'Muestra un panel visual con información estructurada.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      contentType: { type: Type.STRING, enum: ['list', 'detail', 'features_slider'], description: 'El tipo de visualización a mostrar.' },
      title: { type: Type.STRING, description: 'Título del panel.' },
      items: { type: Type.ARRAY, items: { type: Type.OBJECT, properties: { id: { type: Type.STRING }, title: { type: Type.STRING }, description: { type: Type.STRING }, url: { type: Type.STRING }, imageUrl: { type: Type.STRING } }, required: ['id', 'title', 'description'] } },
    },
    required: ['contentType', 'title', 'items'],
  },
};

const CAPTURE_SCREEN_FUNCTION: FunctionDeclaration = {
  name: 'capture_device_screen',
  description: 'Captura y analiza lo que se ve en la PANTALLA del móvil.',
  parameters: { type: Type.OBJECT, properties: {} },
};

const ANALYZE_SECURITY_URL_FUNCTION: FunctionDeclaration = {
  name: 'analyze_security_url',
  description: 'Analiza una URL sospechosa con VirusTotal.',
  parameters: { type: Type.OBJECT, properties: { url: { type: Type.STRING } }, required: ['url'] },
};

const SAVE_VISUAL_MEMORY_FUNCTION: FunctionDeclaration = {
  name: 'save_visual_memory',
  description: 'Guarda un recuerdo visual de un objeto o lugar.',
  parameters: { type: Type.OBJECT, properties: { label: { type: Type.STRING } }, required: ['label'] },
};

const GET_VISUAL_MEMORY_FUNCTION: FunctionDeclaration = {
  name: 'get_visual_memory',
  description: 'Recupera un recuerdo visual guardado.',
  parameters: { type: Type.OBJECT, properties: { label: { type: Type.STRING } }, required: ['label'] },
};

const OPEN_GALLERY_FUNCTION: FunctionDeclaration = {
  name: 'open_gallery',
  description: 'Abre la galería de imágenes o el gestor de archivos. Úsala para que el usuario seleccione una captura de pantalla, foto o documento.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      source: {
        type: Type.STRING,
        enum: ['gallery', 'files'],
        description: 'Usa "gallery" para imágenes/capturas de pantalla y "files" para documentos/ficheros arbitrarios (PDF, APK, etc).',
      },
    },
  },
};

const ANALYZE_IP_FUNCTION: FunctionDeclaration = {
  name: 'analyze_ip',
  description: 'Analiza la reputación de una dirección IP con VirusTotal. Úsala cuando el usuario mencione una IP sospechosa o quiera saber de dónde viene una llamada/conexión.',
  parameters: { type: Type.OBJECT, properties: { ip: { type: Type.STRING, description: 'Dirección IP a analizar' } }, required: ['ip'] },
};

const ANALYZE_DOMAIN_FUNCTION: FunctionDeclaration = {
  name: 'analyze_domain',
  description: 'Analiza la reputación y el historial de un dominio con VirusTotal. Úsala cuando el usuario mencione un dominio web sin URL completa.',
  parameters: { type: Type.OBJECT, properties: { domain: { type: Type.STRING, description: 'Nombre de dominio, ej: example.com' } }, required: ['domain'] },
};

const ANALYZE_FILE_HASH_FUNCTION: FunctionDeclaration = {
  name: 'analyze_file_hash',
  description: 'Consulta VirusTotal usando el hash SHA256 (o MD5/SHA1) de un archivo para saber si es malware conocido.',
  parameters: { type: Type.OBJECT, properties: { hash: { type: Type.STRING, description: 'Hash SHA256, SHA1 o MD5 del archivo' } }, required: ['hash'] },
};

const SCAN_FILE_FUNCTION: FunctionDeclaration = {
  name: 'scan_file',
  description: 'Sube un archivo (APK, PDF, ejecutable) a VirusTotal para analizarlo. El asistente abrirá automáticamente el selector de archivos del dispositivo.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      fileName: { type: Type.STRING, description: 'Nombre del archivo incluyendo extensión' },
    },
    required: ['fileName'],
  },
};

const CHECK_PASSWORD_BREACH_FUNCTION: FunctionDeclaration = {
  name: 'check_password_breach',
  description: 'Verifica de forma segura si una contraseña ha aparecido en brechas de datos conocidas, usando k-Anonymity (la contraseña nunca sale del dispositivo).',
  parameters: { type: Type.OBJECT, properties: { password: { type: Type.STRING, description: 'Contraseña a verificar' } }, required: ['password'] },
};

const GENERATE_PASSWORD_FUNCTION: FunctionDeclaration = {
  name: 'generate_password',
  description: 'Genera una contraseña segura y aleatoria con alta entropía.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      length: { type: Type.NUMBER, description: 'Longitud de la contraseña (mínimo 12, recomendado 20)' },
    },
  },
};

const SCAN_QR_CODE_FUNCTION: FunctionDeclaration = {
  name: 'scan_qr_code',
  description: 'Activa la cámara para que el usuario apunte a un código QR. Extrae la URL y la analiza automáticamente con VirusTotal para detectar phishing.',
  parameters: { type: Type.OBJECT, properties: {} },
};

const AGENT_TOOLS: Tool[] = [
  {
    functionDeclarations: [
      WEB_SEARCH_FUNCTION,
      GET_LOCATION_FUNCTION,
      DESCRIBE_VISION_FUNCTION,
      TOGGLE_FLASHLIGHT_FUNCTION,
      TRIGGER_HAPTIC_FEEDBACK_FUNCTION,
      SWITCH_CAMERA_FUNCTION,
      DISPLAY_CONTENT_FUNCTION,
      CAPTURE_SCREEN_FUNCTION,
      ANALYZE_SECURITY_URL_FUNCTION,
      ANALYZE_IP_FUNCTION,
      ANALYZE_DOMAIN_FUNCTION,
      ANALYZE_FILE_HASH_FUNCTION,
      SCAN_FILE_FUNCTION,
      CHECK_PASSWORD_BREACH_FUNCTION,
      GENERATE_PASSWORD_FUNCTION,
      SCAN_QR_CODE_FUNCTION,
      SAVE_VISUAL_MEMORY_FUNCTION,
      GET_VISUAL_MEMORY_FUNCTION,
      OPEN_GALLERY_FUNCTION,
    ],
  },
];

// ─── Live Session ──────────────────────────────────────────────────────────

export interface LiveSessionOptions {
  systemInstruction?: string;
  responseModalities?: Modality[];
  voiceName?: string;
}

export class GeminiLiveSession extends EventEmitter {
  private session: any; 
  private readonly logger = new Logger('GeminiLiveSession');
  private closed = false;

  constructor(
    private readonly ai: GoogleGenAI,
    private readonly modelId: string,
    private readonly options: LiveSessionOptions = {},
  ) {
    super();
  }

  async connect(): Promise<void> {
    this.logger.log(`Conectando a Live API con modelo: ${this.modelId}`);
    
    // En @google/genai >= 1.0.0, speechConfig e inputAudioTranscription 
    // deben estar en el nivel superior de LiveConnectConfig.
    // inputAudioTranscription DEBE ser un objeto vacío {} para habilitarse.
    const liveConfig: any = {
      responseModalities: this.options.responseModalities ?? [Modality.AUDIO],
      systemInstruction: { 
        parts: [{ 
          text: this.options.systemInstruction || `Eres hiBOB, un guardián digital personal y copiloto de ciberseguridad multimodal.
Tu misión es proteger al usuario en tiempo real frente a amenazas digitales y ayudarle a controlar su privacidad en su móvil.

DIRECTRICES PRINCIPALES:
1. Analista Proactivo (VirusTotal): Actúa inmediatamente ante IPs, URLs, dominios, archivos o QRs sospechosos usando tus herramientas de seguridad. NUNCA leas respuestas en JSON ni datos técnicos puros. Traduce el resultado a lenguaje claro y da una instrucción de acción inmediata (ej. "Ese enlace es peligroso, bórralo inmediatamente").
2. Modo Copiloto: Ayuda al usuario a navegar por los ajustes de su móvil, revisar permisos o mejorar su privacidad, guiándole paso a paso. Usa la captura de pantalla o la cámara si necesitas ver qué tiene delante para darle la instrucción correcta.
3. Contraseñas (HIBP): Verifica filtraciones de contraseñas de forma segura y genera credenciales fuertes.
4. Idioma y Comunicación: Detecta y responde SIEMPRE en el mismo idioma en el que te habla el usuario. Si el usuario se comunica en español, utiliza un claro acento y expresiones propias del español de España. Estás interactuando en tiempo real mediante voz. Habla de forma natural, fluida, empática y directa. No suenes robótico, evita explicaciones técnicas largas y listas interminables.`
        }] 
      },
      tools: AGENT_TOOLS,
      speechConfig: {
        voiceConfig: {
          prebuiltVoiceConfig: {
            voiceName: this.options.voiceName ?? 'Puck', // Voz dinámica o por defecto
          },
        },
      },
      realtimeInputConfig: {
        activityHandling: 'START_OF_ACTIVITY_INTERRUPTS',
      },
    };

    try {
      this.session = await this.ai.live.connect({
        model: this.modelId,
        config: liveConfig,
        callbacks: {
          onmessage: (msg: any) => {
            // Log exhaustivo para depurar estados de interrupción persistentes
            if (msg.serverContent) {
              const { turnComplete, interrupted, modelTurn } = msg.serverContent;
              if (interrupted || turnComplete) {
                this.logger.log(`[Servidor] Evento: turnComplete=${turnComplete}, interrupted=${interrupted}`);
              }
            }
            if (msg.setupComplete) this.logger.log('[Servidor] Setup Complete');
            this._handleSdkMessage(msg);
          },
          onerror: (err: any) => { 
            this.logger.error(`Error de Gemini Live API: ${err.message || JSON.stringify(err)}`); 
            this.emit('error', err); 
          },
          onclose: (event?: any) => { 
            const reason = event?.reason || 'Cierre normal o desconocido';
            const code = event?.code || 'No code';
            this.logger.warn(`Sesión cerrada (Code: ${code}, Reason: ${reason})`); 
            this.closed = true; 
            this.emit('close'); 
          }
        },
      });
      this.logger.log('Conexión con Gemini Live API establecida con éxito');
    } catch (error: any) {
      this.logger.error(`Fallo crítico al conectar con Gemini Live: ${error.message}`);
      throw error;
    }
  }

  private _handleSdkMessage(msg: any) {
    if (msg.serverContent) {
      const { modelTurn, turnComplete, interrupted, inputTranscription, inputAudioTranscription } = msg.serverContent;
      const transcription = inputTranscription?.text || inputAudioTranscription?.text;
      if (transcription) this.emit('transcription', transcription);
      if (modelTurn?.parts) {
        for (const part of modelTurn.parts) {
          if (part.inlineData?.data) this.emit('audio', { data: part.inlineData.data, mimeType: part.inlineData.mimeType });
        }
      }
      if (turnComplete) this.emit('done');
      if (interrupted) {
        this.logger.warn('[Gemini] Interrupción detectada por el servidor');
        this.emit('interruption');
      }
    }
    if (msg.toolCall) this.emit('tool_call', msg.toolCall);
  }

  sendAudioFrame(base64Audio: string, mimeType = 'audio/pcm;rate=16000') {
    if (this.closed || !this.session) return;
    try {
      this.session.sendRealtimeInput({ audio: { mimeType, data: base64Audio } as any });
    } catch (e: any) { this.logger.error(`Error enviando audio: ${e.message}`); }
  }

  /**
   * Envía una señal manual de inicio de actividad para interrumpir al agente.
   */
  async sendActivityStart() {
    if (this.closed || !this.session) return;
    try {
      this.session.sendRealtimeInput({ activityStart: {} } as any);
      this.logger.log('Enviada señal manual de ActivityStart (Interrupción)');
    } catch (e: any) {
      this.logger.error(`Error al enviar ActivityStart: ${e.message}`);
    }
  }

  async sendActivityEnd() {
    if (this.closed || !this.session) return;
    try {
      this.session.sendRealtimeInput({ activityEnd: {} } as any);
      this.logger.log('Enviada señal manual de ActivityEnd');
    } catch (e: any) {
      this.logger.error(`Error al enviar ActivityEnd: ${e.message}`);
    }
  }

  sendImageFrame(base64Image: string, mimeType = 'image/jpeg') {
    if (this.closed || !this.session) return;
    try {
      this.session.sendRealtimeInput({ video: { mimeType, data: base64Image } as any });
    } catch (e: any) { this.logger.error(`Error enviando imagen: ${e.message}`); }
  }

  sendClientContent(parts: any[], turnComplete = true) {
    if (this.closed || !this.session) return;
    try { this.session.sendClientContent({ turns: [{ role: 'user', parts }], turnComplete }); } catch (e: any) { this.logger.error(`Error enviando client content: ${e.message}`); }
  }

  sendToolResponse(toolResponses: any[]) {
    if (this.closed || !this.session) return;
    try { this.session.sendToolResponse({ functionResponses: toolResponses }); } catch (e: any) { this.logger.error(`Error enviando tool response: ${e.message}`); }
  }

  close() { this.closed = true; this.session?.close(); }
  isClosed() { return this.closed; }
}

// ─── Service ───────────────────────────────────────────────────────────────

@Injectable()
export class AiService implements OnModuleInit {
  private readonly logger = new Logger(AiService.name);
  private ai!: GoogleGenAI;
  private modelName!: string;
  private maxOutputTokens!: number;
  private temperature!: number;
  private memory: Map<string, string> = new Map();

  constructor(
    private readonly configService: ConfigService,
    private readonly braveSearchService: BraveSearchService,
    private readonly locationService: LocationService,
    private readonly virusTotalService: VirusTotalService,
    private readonly hibpService: HibpService,
  ) { }

  onModuleInit() {
    const project = this.configService.get<string>('GCP_PROJECT_ID');
    const location = this.configService.get<string>('GCP_LOCATION', 'us-central1');
    this.modelName = this.configService.get<string>('GEMINI_MODEL', 'gemini-2.0-flash');
    this.maxOutputTokens = parseInt(this.configService.get<string>('GEMINI_MAX_OUTPUT_TOKENS', '8192'));
    this.temperature = parseFloat(this.configService.get<string>('GEMINI_TEMPERATURE', '1.0'));

    this.ai = new GoogleGenAI({ vertexai: true, project, location });
    this.logger.log(`AiService inicializado con Vertex AI: ${project}`);
  }

  createLiveSession(options?: LiveSessionOptions): GeminiLiveSession {
    const apiKey = this.configService.get<string>('GEMINI_API_KEY');
    const modelId = this.configService.get<string>('GEMINI_LIVE_MODEL', 'gemini-2.0-flash-exp');
    
    let liveAi: GoogleGenAI;
    if (apiKey) {
      this.logger.log(`Preparando sesión Live con Google AI Studio (API Key)`);
      liveAi = new GoogleGenAI({ apiKey });
    } else {
      this.logger.log(`Preparando sesión Live con Vertex AI (GCP ADC)`);
      liveAi = this.ai;
    }

    // Mapeo de modelos específicos entre AI Studio y Vertex AI (Marzo 2026)
    let effectiveModelId = modelId;
    if (!apiKey) {
      if (modelId === 'gemini-2.5-flash-native-audio-latest') {
        effectiveModelId = 'gemini-live-2.5-flash-native-audio';
        this.logger.log(`[Mapeo Vertex] ${modelId} -> ${effectiveModelId}`);
      } else if (modelId === 'gemini-2.5-flash-preview') {
        effectiveModelId = 'gemini-live-2.5-flash-preview';
        this.logger.log(`[Mapeo Vertex] ${modelId} -> ${effectiveModelId}`);
      }
    }

    return new GeminiLiveSession(liveAi, effectiveModelId, options);
  }

  async generateContent(prompt: string, imageBase64List?: string[], history?: Content[]): Promise<string> {
    const parts: Part[] = [{ text: prompt }];
    if (imageBase64List?.length) imageBase64List.forEach(data => parts.push({ inlineData: { mimeType: 'image/jpeg', data } }));
    const contents: Content[] = [...(history ?? []), { role: 'user' as const, parts }];
    const response = await this.ai.models.generateContent({ model: this.modelName, contents, config: { maxOutputTokens: this.maxOutputTokens, temperature: this.temperature, tools: AGENT_TOOLS } });
    return response.text ?? '';
  }

  async generateContentStream(prompt: string, onChunk: (text: string) => void, imageBase64List?: string[], history?: Content[]): Promise<void> {
    const parts: Part[] = [{ text: prompt }];
    if (imageBase64List?.length) imageBase64List.forEach(data => parts.push({ inlineData: { mimeType: 'image/jpeg', data } }));
    const contents: Content[] = [...(history ?? []), { role: 'user' as const, parts }];
    try {
      const streamResult = await this.ai.models.generateContentStream({ model: this.modelName, contents, config: { maxOutputTokens: this.maxOutputTokens, temperature: this.temperature, tools: AGENT_TOOLS } });
      for await (const chunk of streamResult) if (chunk.text) onChunk(chunk.text);
    } catch (e: any) { this.logger.error(`Error streaming: ${e.message}`); throw e; }
  }

  async processAudio(audioBase64: string, mimeType: string): Promise<string> {
    const response = await this.ai.models.generateContent({ model: this.modelName, contents: [{ role: 'user' as const, parts: [{ text: 'Transcribe el audio.' }, { inlineData: { mimeType, data: audioBase64 } }] }] });
    return response.text ?? '';
  }

  async executeTool(name: string, args: any, socketId: string): Promise<string> {
    if (name === 'web_search') {
      const res = await this.braveSearchService.search(args.query);
      return res.map(r => `[${r.title}](${r.url})`).join('\n');
    }

    if (name === 'analyze_security_url') {
      const rep = await this.virusTotalService.analyzeUrl(args.url);
      
      // Realizamos SIEMPRE una búsqueda web cruzada para dar contexto unificado de internet y VT
      let recentReports = '';
      try {
        const hostname = new URL(args.url).hostname || args.url;
        const searchRes = await this.braveSearchService.search(`"${hostname}" opiniones OR scam OR phishing report`);
        recentReports = searchRes.map(r => r.content).join(' | ').slice(0, 800);
      } catch (e: any) {
        this.logger.error(`Error buscando info web de URL: ${e.message}`);
      }

      const detailsObj = rep.details ? JSON.parse(rep.details) : { positives: rep.positives, total: rep.total, url: args.url };
      detailsObj.internet_context = recentReports ? `Lo que se dice en Internet sobre esta web: ${recentReports}` : 'No hay quejas o reportes recientes destacables en la web abierta.';
      
      return JSON.stringify(detailsObj);
    }

    if (name === 'analyze_ip') {
      const rep = await this.virusTotalService.analyzeIp(args.ip);
      return rep.details || JSON.stringify({ positives: rep.positives, total: rep.total, ip: args.ip });
    }

    if (name === 'analyze_domain') {
      const rep = await this.virusTotalService.analyzeDomain(args.domain);
      return rep.details || JSON.stringify({ positives: rep.positives, total: rep.total, domain: args.domain });
    }

    if (name === 'analyze_file_hash') {
      const rep = await this.virusTotalService.analyzeHash(args.hash);
      return rep.details || JSON.stringify({ positives: rep.positives, total: rep.total, hash: args.hash });
    }

    if (name === 'scan_file_data') {
      const rep = await this.virusTotalService.analyzeFile(args.fileBase64, args.fileName);
      return rep.details || JSON.stringify({ positives: rep.positives, total: rep.total, fileName: args.fileName });
    }

    if (name === 'check_password_breach') {
      const result = await this.hibpService.checkPassword(args.password);
      return JSON.stringify(result);
    }

    if (name === 'generate_password') {
      const length = Math.max(12, Math.min(args.length ?? 20, 64));
      const password = this.hibpService.generateSecurePassword(length);
      return JSON.stringify({ password, length });
    }

    if (name === 'get_current_location') return await this.locationService.getCurrentLocation(socketId);
    if (name === 'save_visual_memory') { this.memory.set(args.label.toLowerCase(), `Guardado el ${new Date().toLocaleString()}`); return 'Memoria guardada.'; }
    if (name === 'get_visual_memory') return this.memory.get(args.label.toLowerCase()) || 'No hay recuerdos.';
    return 'Operación realizada.';
  }
}
