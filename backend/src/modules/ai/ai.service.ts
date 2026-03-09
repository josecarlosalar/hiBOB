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

// ─── Definición de herramientas ──────────────────────────────────────────────

const WEB_SEARCH_FUNCTION: FunctionDeclaration = {
  name: 'web_search',
  description: 'Busca información en internet.',
  parameters: { type: Type.OBJECT, properties: { query: { type: Type.STRING } }, required: ['query'] },
};

const CAPTURE_SCREEN_FUNCTION: FunctionDeclaration = {
  name: 'capture_device_screen',
  description: 'Captura y analiza la PANTALLA del móvil.',
  parameters: { type: Type.OBJECT, properties: {} },
};

const ANALYZE_SECURITY_URL_FUNCTION: FunctionDeclaration = {
  name: 'analyze_security_url',
  description: 'Analiza una URL sospechosa.',
  parameters: { type: Type.OBJECT, properties: { url: { type: Type.STRING } }, required: ['url'] },
};

const AGENT_TOOLS: Tool[] = [
  {
    functionDeclarations: [
      WEB_SEARCH_FUNCTION,
      CAPTURE_SCREEN_FUNCTION,
      ANALYZE_SECURITY_URL_FUNCTION,
      { name: 'get_current_location', description: 'Obtiene ubicación.', parameters: { type: Type.OBJECT, properties: {} } },
      { name: 'describe_camera_view', description: 'Ve por la cámara.', parameters: { type: Type.OBJECT, properties: {} } },
      { name: 'toggle_flashlight', description: 'Linterna.', parameters: { type: Type.OBJECT, properties: { enabled: { type: Type.BOOLEAN } } }, required: ['enabled'] },
    ],
  },
];

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
      systemInstruction: {
        parts: [{ text: this.options.systemInstruction || 'Eres hiBOB, una asistente multimodal útil y rápida.' }],
      },
      tools: AGENT_TOOLS,
    };

    this.session = await this.ai.live.connect({
      model: this.modelId,
      config: liveConfig,
      callbacks: {
        onmessage: (msg: any) => this._handleSdkMessage(msg),
        onerror: (err: any) => {
          this.logger.error(`Error de Gemini: ${err.message || err}`);
          this.emit('error', err);
        },
        onclose: () => {
          this.logger.warn('Sesión de Gemini cerrada');
          this.closed = true;
          this.emit('close');
        }
      },
    });
  }

  private _handleSdkMessage(msg: any) {
    if (msg.serverContent) {
      const { modelTurn, turnComplete, interrupted, inputTranscription } = msg.serverContent;
      if (inputTranscription?.text) this.emit('transcription', inputTranscription.text);
      if (modelTurn?.parts) {
        for (const part of modelTurn.parts) {
          if (part.inlineData?.data) {
            this.emit('audio', { data: part.inlineData.data, mimeType: part.inlineData.mimeType });
          }
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
      // Formato explícito realtimeInput para asegurar compatibilidad
      this.session.send({
        realtimeInput: {
          mediaChunks: [{ data: base64Audio, mimeType }]
        }
      });
    } catch (e) { this.logger.error(`Error enviando audio: ${e.message}`); }
  }

  sendImageFrame(base64Image: string, mimeType = 'image/jpeg') {
    if (this.closed || !this.session) return;
    this.session.send({
      realtimeInput: {
        mediaChunks: [{ data: base64Image, mimeType }]
      }
    });
  }

  sendClientContent(parts: any[], turnComplete = true) {
    if (this.closed || !this.session) return;
    this.session.send({
      clientContent: {
        turns: [{ role: 'user', parts }],
        turnComplete
      }
    });
  }

  sendToolResponse(toolResponses: any[]) {
    if (this.closed || !this.session) return;
    this.session.send({
      toolResponse: {
        functionResponses: toolResponses
      }
    });
  }

  close() { this.closed = true; this.session?.close(); }
  isClosed() { return this.closed; }
}

@Injectable()
export class AiService implements OnModuleInit {
  private readonly logger = new Logger(AiService.name);
  private ai: GoogleGenAI;

  constructor(
    private readonly configService: ConfigService,
    private readonly braveSearchService: BraveSearchService,
    private readonly locationService: LocationService,
    private readonly virusTotalService: VirusTotalService,
  ) { }

  onModuleInit() {
    const project = this.configService.get<string>('GCP_PROJECT_ID');
    const location = this.configService.get<string>('GCP_LOCATION', 'us-central1');
    // Usar Vertex AI si no hay API Key
    this.ai = new GoogleGenAI({ vertexai: true, project, location });
    this.logger.log('AiService inicializado con Vertex AI');
  }

  async createLiveSession(options?: LiveSessionOptions): Promise<GeminiLiveSession> {
    const apiKey = this.configService.get<string>('GEMINI_API_KEY');
    const modelId = this.configService.get<string>('GEMINI_LIVE_MODEL', 'gemini-2.0-flash-exp');
    
    const liveAi = apiKey ? new GoogleGenAI({ apiKey }) : this.ai;
    const session = new GeminiLiveSession(liveAi, modelId, options);
    await session.connect();
    return session;
  }

  async executeTool(name: string, args: any, socketId: string): Promise<string> {
    if (name === 'web_search') {
      const res = await this.braveSearchService.search(args.query);
      return res.map(r => r.title + ': ' + r.url).join('\n');
    }
    if (name === 'analyze_security_url') {
      const rep = await this.virusTotalService.analyzeUrl(args.url);
      return `Reporte: ${rep.status}. Riesgo: ${rep.positives}/${rep.total}`;
    }
    if (name === 'get_current_location') return await this.locationService.getCurrentLocation(socketId);
    return 'Hecho.';
  }
}
