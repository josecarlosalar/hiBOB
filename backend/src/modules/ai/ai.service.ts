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
  description: 'Describe lo que ve la cámara frontal o trasera.',
  parameters: { type: Type.OBJECT, properties: {} },
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
      type: { type: Type.STRING, enum: ['list', 'detail'] },
      title: { type: Type.STRING },
      items: { type: Type.ARRAY, items: { type: Type.OBJECT, properties: { id: { type: Type.STRING }, title: { type: Type.STRING }, description: { type: Type.STRING }, url: { type: Type.STRING }, imageUrl: { type: Type.STRING } } } },
    },
    required: ['type', 'title', 'items'],
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
  description: 'Abre la galería de imágenes del dispositivo para que el usuario seleccione una captura de pantalla o foto.',
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
    const liveConfig: any = {
      responseModalities: this.options.responseModalities ?? [Modality.AUDIO],
      systemInstruction: { parts: [{ text: this.options.systemInstruction || 'Eres hiBOB, una asistente multimodal útil.' }] },
      tools: AGENT_TOOLS,
    };

    this.session = await this.ai.live.connect({
      model: this.modelId,
      config: liveConfig,
      callbacks: {
        onmessage: (msg: any) => this._handleSdkMessage(msg),
        onerror: (err: any) => { this.logger.error(`Error de Gemini: ${err.message || err}`); this.emit('error', err); },
        onclose: () => { this.logger.warn('Sesión cerrada'); this.closed = true; this.emit('close'); }
      },
    });
  }

  private _handleSdkMessage(msg: any) {
    if (msg.serverContent) {
      const { modelTurn, turnComplete, interrupted, inputTranscription } = msg.serverContent;
      if (inputTranscription?.text) this.emit('transcription', inputTranscription.text);
      if (modelTurn?.parts) {
        for (const part of modelTurn.parts) {
          if (part.inlineData?.data) this.emit('audio', { data: part.inlineData.data, mimeType: part.inlineData.mimeType });
        }
      }
      if (turnComplete) this.emit('done');
      if (interrupted) this.emit('interruption');
    }
    if (msg.toolCall) this.emit('tool_call', msg.toolCall);
  }

  sendAudioFrame(base64Audio: string, mimeType = 'audio/pcm;rate=16000') {
    if (this.closed || !this.session) return;
    try {
      this.session.sendRealtimeInput({ audio: { mimeType, data: base64Audio } as any });
    } catch (e) { this.logger.error(`Error enviando audio: ${e.message}`); }
  }

  sendImageFrame(base64Image: string, mimeType = 'image/jpeg') {
    if (this.closed || !this.session) return;
    try {
      this.session.sendRealtimeInput({ video: { mimeType, data: base64Image } as any });
    } catch (e) { this.logger.error(`Error enviando imagen: ${e.message}`); }
  }

  sendClientContent(parts: any[], turnComplete = true) {
    if (this.closed || !this.session) return;
    try { this.session.sendClientContent({ turns: [{ role: 'user', parts }], turnComplete }); } catch (e) { this.logger.error(`Error enviando client content: ${e.message}`); }
  }

  sendToolResponse(toolResponses: any[]) {
    if (this.closed || !this.session) return;
    try { this.session.sendToolResponse({ functionResponses: toolResponses }); } catch (e) { this.logger.error(`Error enviando tool response: ${e.message}`); }
  }

  close() { this.closed = true; this.session?.close(); }
  isClosed() { return this.closed; }
}

// ─── Service ───────────────────────────────────────────────────────────────

@Injectable()
export class AiService implements OnModuleInit {
  private readonly logger = new Logger(AiService.name);
  private ai: GoogleGenAI;
  private modelName: string;
  private maxOutputTokens: number;
  private temperature: number;
  private memory: Map<string, string> = new Map();

  constructor(
    private readonly configService: ConfigService,
    private readonly braveSearchService: BraveSearchService,
    private readonly locationService: LocationService,
    private readonly virusTotalService: VirusTotalService,
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

  async createLiveSession(options?: LiveSessionOptions): Promise<GeminiLiveSession> {
    const apiKey = this.configService.get<string>('GEMINI_API_KEY');
    const modelId = this.configService.get<string>('GEMINI_LIVE_MODEL', 'gemini-2.0-flash-exp');
    const liveAi = apiKey ? new GoogleGenAI({ apiKey }) : this.ai;
    const session = new GeminiLiveSession(liveAi, modelId, options);
    await session.connect();
    return session;
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
    } catch (e) { this.logger.error(`Error streaming: ${e.message}`); throw e; }
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
      return `REPORTE: ${rep.status}. Riesgo: ${rep.positives}/${rep.total} motores.`;
    }
    if (name === 'get_current_location') return await this.locationService.getCurrentLocation(socketId);
    if (name === 'save_visual_memory') { this.memory.set(args.label.toLowerCase(), `Guardado el ${new Date().toLocaleString()}`); return 'Memoria guardada.'; }
    if (name === 'get_visual_memory') return this.memory.get(args.label.toLowerCase()) || 'No hay recuerdos.';
    return 'Operación realizada.';
  }
}
