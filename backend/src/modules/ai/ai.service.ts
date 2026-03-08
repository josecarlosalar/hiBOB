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
import { TavilyService } from '../tools/tavily.service';
import { LocationService } from '../tools/location.service';
import { GoogleAuth } from 'google-auth-library';
import { EventEmitter } from 'events';
import { inspect } from 'util';

// ─── Definición de herramientas disponibles ──────────────────────────────────

const WEB_SEARCH_FUNCTION: FunctionDeclaration = {
  name: 'web_search',
  description:
    'Busca información actualizada en internet. Úsala cuando necesites datos recientes, noticias, precios, o cualquier información que puedas no tener en tu conocimiento.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      query: {
        type: Type.STRING,
        description: 'La consulta de búsqueda en lenguaje natural',
      },
    },
    required: ['query'],
  },
};

const GET_LOCATION_FUNCTION: FunctionDeclaration = {
  name: 'get_current_location',
  description:
    'Obtiene la ubicación actual del usuario (calle, ciudad). Úsala para dar contexto sobre dónde se encuentra el usuario.',
  parameters: {
    type: Type.OBJECT,
    properties: {},
  },
};

const DETECT_HAZARDS_FUNCTION: FunctionDeclaration = {
  name: 'detect_safety_hazards',
  description:
    'Realiza un escaneo de seguridad de alta prioridad sobre la imagen de la cámara. Úsala cuando el usuario camine, se mueva o pregunte si es seguro avanzar. Esta herramienta activa un análisis detallado de obstáculos, desniveles y tráfico.',
  parameters: {
    type: Type.OBJECT,
    properties: {},
  },
};

const DESCRIBE_VISION_FUNCTION: FunctionDeclaration = {
  name: 'describe_camera_view',
  description:
    'Captura una imagen de la cámara actual (frontal o trasera) y describe lo que hay delante. Úsala cuando el usuario pregunte "¿qué ves?", "¿puedes verme?", "¿qué hay delante de mí?" o cualquier pregunta sobre el entorno visual.',
  parameters: {
    type: Type.OBJECT,
    properties: {},
  },
};

const TOGGLE_FLASHLIGHT_FUNCTION: FunctionDeclaration = {
  name: 'toggle_flashlight',
  description: 'Enciende o apaga la linterna del dispositivo móvil. Úsala si la imagen está oscura o si el usuario lo solicita.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      enabled: { type: Type.BOOLEAN, description: 'True para encender, False para apagar' },
    },
    required: ['enabled'],
  },
};

const TRIGGER_HAPTIC_FEEDBACK_FUNCTION: FunctionDeclaration = {
  name: 'trigger_haptic_feedback',
  description: 'Hace que el teléfono vibre. Úsala para alertas críticas o confirmaciones silenciosas.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      pattern: { type: Type.STRING, enum: ['success', 'warning', 'error', 'heavy'], description: 'El tipo de vibración' },
    },
    required: ['pattern'],
  },
};

const MARK_PLACE_FUNCTION: FunctionDeclaration = {
  name: 'mark_place',
  description: 'Guarda la ubicación actual y lo que el usuario está viendo (ej. "mis llaves", "la puerta"). Permite recordar dónde están las cosas.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      label: { type: Type.STRING, description: 'Nombre del objeto o lugar a recordar' },
    },
    required: ['label'],
  },
};

const GET_DIRECTIONS_FUNCTION: FunctionDeclaration = {
  name: 'get_navigation_directions',
  description: 'Obtiene la ruta hacia un destino. Úsala cuando el usuario quiera ir a un sitio específico.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      destination: { type: Type.STRING, description: 'El lugar de destino' },
    },
    required: ['destination'],
  },
};

const SWITCH_CAMERA_FUNCTION: FunctionDeclaration = {
  name: 'switch_camera',
  description: 'Cambia entre la cámara frontal (selfie) y la trasera (entorno). Úsala cuando el usuario pida cambiar de cámara o ver lo que hay al otro lado.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      direction: { type: Type.STRING, enum: ['front', 'back'], description: 'La dirección de la cámara a activar' },
    },
    required: ['direction'],
  },
};

const DISPLAY_CONTENT_FUNCTION: FunctionDeclaration = {
  name: 'display_content',
  description: 'Muestra un panel visual con información estructurada (listas, noticias, recetas, productos). Úsala cuando encuentres información que el usuario deba ver en pantalla.',
  parameters: {
    type: Type.OBJECT,
    properties: {
      type: { type: Type.STRING, enum: ['list', 'detail'], description: 'El tipo de visualización' },
      title: { type: Type.STRING, description: 'Título del panel' },
      items: {
        type: Type.ARRAY,
        description: 'Lista de elementos a mostrar',
        items: {
          type: Type.OBJECT,
          properties: {
            id: { type: Type.STRING },
            title: { type: Type.STRING },
            description: { type: Type.STRING },
            url: { type: Type.STRING, description: 'URL de la fuente original' },
            imageUrl: { type: Type.STRING, description: 'URL de imagen opcional' },
            metadata: { type: Type.OBJECT, description: 'Datos extra como ingredientes, pasos, precio, etc.' },
          },
        },
      },
    },
    required: ['type', 'title', 'items'],
  },
};

const CAPTURE_SCREEN_FUNCTION: FunctionDeclaration = {
  name: 'capture_device_screen',
  description: 'Captura y analiza lo que se ve en la PANTALLA del móvil (ajustes, menús, apps). Úsala SIEMPRE que el usuario pida ayuda para configurar el teléfono o usar una aplicación. NUNCA uses la cámara para ver el software del móvil.',
  parameters: {
    type: Type.OBJECT,
    properties: {},
  },
};

const AGENT_TOOLS: Tool[] = [
  {
    functionDeclarations: [
      WEB_SEARCH_FUNCTION,
      GET_LOCATION_FUNCTION,
      DETECT_HAZARDS_FUNCTION,
      DESCRIBE_VISION_FUNCTION,
      TOGGLE_FLASHLIGHT_FUNCTION,
      TRIGGER_HAPTIC_FEEDBACK_FUNCTION,
      MARK_PLACE_FUNCTION,
      GET_DIRECTIONS_FUNCTION,
      SWITCH_CAMERA_FUNCTION,
      DISPLAY_CONTENT_FUNCTION,
      CAPTURE_SCREEN_FUNCTION,
    ],
  },
];

// ─── Interfaces para Live API ────────────────────────────────────────────────

export interface LiveSessionOptions {
  systemInstruction?: string;
  minimalConfig?: boolean;
  disableTools?: boolean;
  disableSpeechConfig?: boolean;
  disableTranscriptions?: boolean;
  responseModalities?: Modality[];
  verboseLogs?: boolean;
}

/**
 * Sesión Live con Gemini usando el SDK oficial @google/genai.
 */
export class GeminiLiveSession extends EventEmitter {
  private session: any; 
  private readonly logger = new Logger(GeminiLiveSession.name);
  private closed = false;
  private lastErrorMessage: string | null = null;
  private sdkMsgCount = 0;

  constructor(
    private readonly ai: GoogleGenAI,
    private readonly modelId: string,
    private readonly options: LiveSessionOptions = {},
  ) {
    super();
  }

  async connect(): Promise<void> {
    this.logger.log(`Abriendo Gemini Live session (model=${this.modelId})`);
    const useMinimal = this.options.minimalConfig ?? false;
    const includeTools = !useMinimal && !(this.options.disableTools ?? false);
    const includeSpeechConfig =
      !useMinimal && !(this.options.disableSpeechConfig ?? false);
    const includeTranscriptions =
      !useMinimal && !(this.options.disableTranscriptions ?? false);

    const liveConfig: any = {
      responseModalities: this.options.responseModalities ?? [Modality.AUDIO],
      systemInstruction: {
        parts: [
          {
            text:
              this.options.systemInstruction ||
              'Eres hiBOB, un asistente amable para personas con discapacidad visual. Responde de forma concisa y natural.',
          },
        ],
      },
    };

    if (includeSpeechConfig) {
      liveConfig.speechConfig = {
        voiceConfig: { prebuiltVoiceConfig: { voiceName: 'Aoede' } },
      };
    }

    if (includeTranscriptions) {
      liveConfig.inputAudioTranscription = {};
      liveConfig.outputAudioTranscription = {};
    }

    if (includeTools) {
      liveConfig.tools = AGENT_TOOLS;
    }

    this.session = await this.ai.live.connect({
      model: this.modelId,
      config: liveConfig,
      callbacks: {
        onmessage: (msg: any) => {
          if (!this.closed) this._handleSdkMessage(msg);
        },
        onerror: (err: any) => {
          const message = err?.message || err?.error || String(err);
          this.lastErrorMessage = message;
          this.logger.error(`Error en Gemini: ${message}`);
          if (!this.closed) this.emit('error', new Error(message));
        },
        onclose: (...args: any[]) => {
          if (this.lastErrorMessage == null && args.length > 0) {
            const first = args[0];
            const closeReason = first?.reason ?? first?.message ?? (typeof first === 'string' ? first : null);
            if (closeReason) this.lastErrorMessage = String(closeReason);
          }
          this.logger.warn(`Gemini Live SDK: loop cerrado${this.lastErrorMessage != null ? ` (${this.lastErrorMessage})` : ''}`);
          if (!this.closed) {
            this.closed = true;
            this.session = null;
            this.emit('close', this.lastErrorMessage);
          }
        }
      },
    });
    this.logger.log(`[V2.1] GeminiLiveSession conectada via SDK (model=${this.modelId})`);
  }

  private _handleSdkMessage(msg: any) {
    this.sdkMsgCount += 1;
    if (msg.serverContent) {
      const { modelTurn, turnComplete, interrupted, inputTranscription } = msg.serverContent;

      if (inputTranscription?.text) {
        this.emit('transcription', inputTranscription.text);
      }

      if (modelTurn?.parts) {
        for (const part of modelTurn.parts) {
          if (part.inlineData?.data) {
            this.emit('audio', {
              data: part.inlineData.data,
              mimeType: part.inlineData.mimeType ?? null,
            });
          }
        }
      }
      if (turnComplete) this.emit('done');
      if (interrupted) this.emit('interruption');
    }

    if (msg.toolCall) {
      this.logger.log(`Gemini Tool Call: ${JSON.stringify(msg.toolCall)}`);
      this.emit('tool_call', msg.toolCall);
    }
  }

  sendAudioFrame(base64Audio: string, mimeType = 'audio/pcm;rate=16000') {
    if (!this.session || this.closed) return;
    try {
      this.session.sendRealtimeInput({ audio: { data: base64Audio, mimeType } });
    } catch (err) {
      this.logger.error(`Error en sendAudioFrame: ${err.message}`);
    }
  }

  sendImageFrame(base64Image: string, mimeType = 'image/jpeg') {
    if (!this.session || this.closed) return;
    try {
      this.session.sendRealtimeInput({ video: { data: base64Image, mimeType } });
    } catch (err) {
      this.logger.error(`Error en sendImageFrame: ${err.message}`);
    }
  }

  sendToolResponse(toolResponses: any[]) {
    if (!this.session || this.closed) return;
    this.session.sendToolResponse({ functionResponses: toolResponses });
  }

  close() {
    this.closed = true;
    this.session?.close();
  }

  isClosed(): boolean {
    return this.closed;
  }
}

// ─── Servicio ─────────────────────────────────────────────────────────────────

@Injectable()
export class AiService implements OnModuleInit {
  private readonly logger = new Logger(AiService.name);
  private ai: GoogleGenAI;
  private modelName: string;
  private fallbackModelName: string;
  private maxOutputTokens: number;
  private temperature: number;
  private memory: Map<string, string> = new Map();

  constructor(
    private readonly configService: ConfigService,
    private readonly tavilyService: TavilyService,
    private readonly locationService: LocationService,
  ) { }

  onModuleInit() {
    const project = this.configService.get<string>('GCP_PROJECT_ID');
    const location = this.configService.get<string>('GCP_LOCATION', 'us-central1');
    this.modelName = this.configService.get<string>('GEMINI_MODEL', 'gemini-2.5-flash');
    this.fallbackModelName = this.configService.get<string>('GEMINI_FALLBACK_MODEL', 'gemini-2.5-flash');
    this.maxOutputTokens = parseInt(this.configService.get<string>('GEMINI_MAX_OUTPUT_TOKENS', '8192'));
    this.temperature = parseFloat(this.configService.get<string>('GEMINI_TEMPERATURE', '1.0'));

    this.ai = new GoogleGenAI({ vertexai: true, project, location });
    this.logger.log(`Google GenAI inicializado: proyecto=${project}, modelo=${this.modelName}`);
  }

  private async generateContentWithModelFallback(request: any): Promise<any> {
    try {
      return await this.ai.models.generateContent(request);
    } catch (error) {
      this.logger.warn(`Error en generación, reintentando con fallback: ${error.message}`);
      return await this.ai.models.generateContent({ ...request, model: this.fallbackModelName });
    }
  }

  async createLiveSession(options?: LiveSessionOptions): Promise<GeminiLiveSession> {
    const modelId = this.configService.get<string>('GEMINI_LIVE_MODEL', 'gemini-2.5-flash-native-audio-latest');
    const apiKey = this.configService.get<string>('GEMINI_API_KEY');
    if (!apiKey) throw new Error('GEMINI_API_KEY no configurada.');

    const liveAi = new GoogleGenAI({ apiKey });
    const session = new GeminiLiveSession(liveAi, modelId, options);
    await session.connect();
    return session;
  }

  private async executeTool(name: string, args: Record<string, unknown>, socketId?: string): Promise<string> {
    if (name === 'web_search') {
      const results = await this.tavilyService.search(args['query'] as string);
      if (!results.length) return 'No se encontraron resultados.';
      return results.map((r, i) => `[${i + 1}] ${r.title}\n${r.url}\n${r.content}`).join('\n\n');
    }
    if (name === 'get_current_location') return await this.locationService.getCurrentLocation(socketId);
    if (name === 'detect_safety_hazards') return 'SISTEMA DE SEGURIDAD ACTIVADO: Analiza la imagen buscando peligros.';
    if (name === 'describe_camera_view') return 'IMAGEN CAPTURADA: Describe lo que ves de forma natural.';
    if (name === 'toggle_flashlight') return `Linterna ${args['enabled'] ? 'encendida' : 'apagada'}.`;
    if (name === 'switch_camera') return `Cámara cambiada a ${args['direction'] === 'front' ? 'frontal' : 'trasera'}.`;
    if (name === 'display_content') return `Panel visual "${args['title']}" mostrado correctamente.`;
    if (name === 'observe_screen') return 'PANTALLA CAPTURADA: Analiza la interfaz para guiar al usuario.';
    if (name === 'trigger_haptic_feedback') return 'Vibración enviada.';
    
    return `Herramienta "${name}" no implementada.`;
  }

  async generateContent(prompt: string, imageBase64List?: string[], history?: Content[]): Promise<string> {
    const parts: Part[] = [{ text: prompt }];
    if (imageBase64List?.length) {
      for (const base64 of imageBase64List) {
        parts.push({ inlineData: { mimeType: 'image/jpeg', data: base64 } });
      }
    }
    const contents: Content[] = [...(history ?? []), { role: 'user' as const, parts }];
    const response = await this.generateContentWithModelFallback({
      model: this.modelName,
      contents,
      config: { maxOutputTokens: this.maxOutputTokens, temperature: this.temperature, tools: AGENT_TOOLS },
    });
    return response.text ?? '';
  }

  async generateContentStream(
    prompt: string,
    onChunk: (text: string) => void,
    imageBase64List?: string[],
    history?: Content[],
  ): Promise<void> {
    const parts: Part[] = [{ text: prompt }];
    if (imageBase64List?.length) {
      for (const base64 of imageBase64List) {
        parts.push({ inlineData: { mimeType: 'image/jpeg', data: base64 } });
      }
    }

    const contents: Content[] = [...(history ?? []), { role: 'user' as const, parts }];

    try {
      const streamResult = await this.ai.models.generateContentStream({
        model: this.modelName,
        contents,
        config: { maxOutputTokens: this.maxOutputTokens, temperature: this.temperature, tools: AGENT_TOOLS },
      });

      for await (const chunk of streamResult) {
        const text = chunk.text;
        if (text) onChunk(text);
      }
    } catch (error) {
      this.logger.error(`Error en generateContentStream: ${error.message}`);
      throw error;
    }
  }

  async processAudio(audioBase64: string, mimeType: string): Promise<string> {
    const response = await this.ai.models.generateContent({
      model: this.modelName,
      contents: [{
        role: 'user' as const,
        parts: [
          { text: 'Transcribe el audio exactamente.' },
          { inlineData: { mimeType, data: audioBase64 } },
        ],
      }],
    });
    return response.text ?? '';
  }
}
