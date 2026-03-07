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
 * Usa g.live.connect() que gestiona internamente el protocolo WebSocket.
 */
export class GeminiLiveSession extends EventEmitter {
  private session: any; // LiveSession del SDK
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

    this.logger.log(
      `Live config: minimal=${useMinimal}, tools=${includeTools}, speech=${includeSpeechConfig}, transcriptions=${includeTranscriptions}`,
    );

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
          if (this.options.verboseLogs ?? false) {
            this.logger.error(`Error en Gemini (raw): ${inspect(err, { depth: 6 })}`);
          }
          if (!this.closed) this.emit('error', new Error(message));
        },
        onclose: (...args: any[]) => {
          if (this.lastErrorMessage == null && args.length > 0) {
            const first = args[0];
            const closeReason =
              first?.reason ??
              first?.message ??
              (typeof first === 'string' ? first : null);
            if (closeReason) {
              this.lastErrorMessage = String(closeReason);
            }
          }
          this.logger.warn(
            `Gemini Live SDK: loop cerrado${this.lastErrorMessage != null ? ` (${this.lastErrorMessage})` : ''}`,
          );
          if (!this.closed) {
            this.closed = true;
            this.session = null; // Liberar referencia
            this.emit('close', this.lastErrorMessage);
          }
        }
      },
    });
    this.logger.log(`[V2.1] GeminiLiveSession conectada via SDK (model=${this.modelId})`);
  }

  private _handleSdkMessage(msg: any) {
    this.sdkMsgCount += 1;
    const keys = Object.keys(msg).join(',');
    if (this.options.verboseLogs ?? false) {
      this.logger.log(
        `[SDK MSG #${this.sdkMsgCount}] Keys: ${keys} | raw: ${JSON.stringify(msg).substring(0, 200)}`,
      );
    } else {
      this.logger.log(`[SDK MSG #${this.sdkMsgCount}] Keys: ${keys}`);
    }

    if (msg.serverContent) {
      const { modelTurn, turnComplete, interrupted, outputTranscription, inputTranscription } = msg.serverContent;

      // Transcripción del audio del usuario (lo que dijo el usuario)
      if (inputTranscription?.text) {
        this.logger.log(`Input Transcription: ${inputTranscription.text}`);
        this.emit('transcription', inputTranscription.text);
      }

      // Transcripción de la respuesta de Gemini (para logs, no se envía al móvil como texto)
      if (outputTranscription?.text) {
        this.logger.log(`Output Transcription: ${outputTranscription.text}`);
      }

      if (modelTurn?.parts) {
        for (const part of modelTurn.parts) {
          // Audio de respuesta (PCM 24kHz del modelo nativo)
          if (part.inlineData?.data) {
            if (this.options.verboseLogs ?? false) {
              this.logger.log(`Gemini Audio Part: ${part.inlineData.data.length} bytes`);
            }
            this.emit('audio', {
              data: part.inlineData.data,
              mimeType: part.inlineData.mimeType ?? null,
            });
          }
        }
      }
      if (turnComplete) {
        this.logger.log(`[SDK] Turn Complete (msgs=${this.sdkMsgCount})`);
        this.emit('done');
      }
      if (interrupted) {
        this.logger.warn(`[SDK] Model Interrupted (msgs=${this.sdkMsgCount})`);
        this.emit('interruption');
      }
    }

    // toolCall: llamadas a herramientas del agente
    if (msg.toolCall) {
      this.logger.log(`Gemini Tool Call: ${JSON.stringify(msg.toolCall)}`);
      this.emit('tool_call', msg.toolCall);
    }
  }

  sendAudioFrame(base64Audio: string, mimeType = 'audio/pcm;rate=16000') {
    if (!this.session || this.closed) return;
    try {
      this.session.sendRealtimeInput({
        audio: { data: base64Audio, mimeType },
      });
    } catch (err) {
      this.logger.error(`Error en sendAudioFrame: ${err.message}`);
    }
  }

  /** Envía un frame de imagen via sendRealtimeInput (no interrumpe el flujo de audio). */
  sendImageFrame(base64Image: string, mimeType = 'image/jpeg') {
    if (!this.session || this.closed) return;
    try {
      this.session.sendRealtimeInput({
        video: { data: base64Image, mimeType },
      });
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

  getLastErrorMessage(): string | null {
    return this.lastErrorMessage;
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
  private auth: GoogleAuth;
  private memory: Map<string, string> = new Map(); // Memoria persistente simple para lugares

  constructor(
    private readonly configService: ConfigService,
    private readonly tavilyService: TavilyService,
    private readonly locationService: LocationService,
  ) { }

  onModuleInit() {
    const project = this.configService.get<string>('GCP_PROJECT_ID');
    const location = this.configService.get<string>('GCP_LOCATION', 'us-central1');
    this.modelName = this.configService.get<string>('GEMINI_MODEL', 'gemini-2.5-flash');
    this.fallbackModelName = this.configService.get<string>(
      'GEMINI_FALLBACK_MODEL',
      'gemini-2.5-flash',
    );
    this.maxOutputTokens = parseInt(
      this.configService.get<string>('GEMINI_MAX_OUTPUT_TOKENS', '8192'),
    );
    this.temperature = parseFloat(
      this.configService.get<string>('GEMINI_TEMPERATURE', '1.0'),
    );

    this.ai = new GoogleGenAI({ vertexai: true, project, location });
    this.auth = new GoogleAuth({
      scopes: ['https://www.googleapis.com/auth/cloud-platform'],
    });

    this.logger.log(
      `Google GenAI inicializado: proyecto=${project}, modelo=${this.modelName}, fallback=${this.fallbackModelName}`,
    );
  }

  private isModelNotFoundError(error: unknown): boolean {
    const msg =
      error instanceof Error
        ? error.message
        : typeof error === 'string'
          ? error
          : JSON.stringify(error);
    return (
      msg.includes('Publisher Model') &&
      msg.includes('NOT_FOUND') &&
      (msg.includes('"code":404') || msg.includes('"code": 404'))
    );
  }

  private async generateContentWithModelFallback(request: any): Promise<any> {
    try {
      return await this.ai.models.generateContent(request);
    } catch (error) {
      if (
        !this.isModelNotFoundError(error) ||
        request.model === this.fallbackModelName
      ) {
        throw error;
      }

      this.logger.warn(
        `Modelo no disponible en Vertex (${request.model}). Reintentando con fallback=${this.fallbackModelName}`,
      );
      this.modelName = this.fallbackModelName;
      return await this.ai.models.generateContent({
        ...request,
        model: this.fallbackModelName,
      });
    }
  }

  private async generateContentStreamWithModelFallback(
    request: any,
  ): Promise<any> {
    try {
      return await this.ai.models.generateContentStream(request);
    } catch (error) {
      if (
        !this.isModelNotFoundError(error) ||
        request.model === this.fallbackModelName
      ) {
        throw error;
      }

      this.logger.warn(
        `Modelo stream no disponible en Vertex (${request.model}). Reintentando con fallback=${this.fallbackModelName}`,
      );
      this.modelName = this.fallbackModelName;
      return await this.ai.models.generateContentStream({
        ...request,
        model: this.fallbackModelName,
      });
    }
  }

  // ─── Live Session ──────────────────────────────────────────────────────────

  async createLiveSession(options?: LiveSessionOptions): Promise<GeminiLiveSession> {
    // Modelo Live multimodal (audio + imagen) para la sesión en tiempo real.
    const modelId = this.configService.get<string>(
      'GEMINI_LIVE_MODEL',
      'gemini-2.5-flash-native-audio-latest',
    );

    // Autenticación: si hay GEMINI_API_KEY usa AI Studio (más sencillo, sin IAM).
    // Si no hay key, usa Vertex AI con ADC (Service Account en Cloud Run).
    const apiKey = this.configService.get<string>('GEMINI_API_KEY');
    if (!apiKey) {
      throw new Error('GEMINI_API_KEY no configurada. Se requiere para Live API con AI Studio.');
    }
    this.logger.log(`Live API: usando AI Studio key (model=${modelId})`);
    // Crear instancia separada sin vertexai ni project para evitar que el SDK
    // ignore la apiKey en favor de ADC/Vertex.
    const liveAi = new GoogleGenAI({ apiKey });
    const minimalConfig =
      this.configService.get<string>('GEMINI_LIVE_MINIMAL_CONFIG', 'false') ===
      'true';
    const disableTools =
      this.configService.get<string>('GEMINI_LIVE_DISABLE_TOOLS', 'false') ===
      'true';
    const disableSpeechConfig =
      this.configService.get<string>('GEMINI_LIVE_DISABLE_SPEECH_CONFIG', 'false') ===
      'true';
    const disableTranscriptions =
      this.configService.get<string>('GEMINI_LIVE_DISABLE_TRANSCRIPTIONS', 'false') ===
      'true';
    const verboseLogs =
      this.configService.get<string>('GEMINI_LIVE_DEBUG_VERBOSE', 'false') ===
      'true';

    this.logger.log(
      `Live session settings: model=${modelId}, minimal=${minimalConfig}, disableTools=${disableTools}, disableSpeech=${disableSpeechConfig}, disableTranscriptions=${disableTranscriptions}, verbose=${verboseLogs}`,
    );

    const liveOptions: LiveSessionOptions = {
      ...options,
      minimalConfig,
      disableTools,
      disableSpeechConfig,
      disableTranscriptions,
      verboseLogs,
    };

    const session = new GeminiLiveSession(liveAi, modelId, liveOptions);
    await session.connect();
    return session;
  }

  // ─── Llamada a herramienta ─────────────────────────────────────────────────

  private async executeTool(
    name: string,
    args: Record<string, unknown>,
    socketId?: string,
  ): Promise<string> {
    if (name === 'web_search') {
      const query = args['query'] as string;
      const results = await this.tavilyService.search(query);
      if (!results.length) return 'No se encontraron resultados.';
      return results
        .map((r, i) => `[${i + 1}] ${r.title}\n${r.url}\n${r.content}`)
        .join('\n\n');
    }

    if (name === 'get_current_location') {
      return await this.locationService.getCurrentLocation(socketId);
    }

    if (name === 'detect_safety_hazards') {
      this.logger.log('Ejecutando escaneo de seguridad detallado...');
      return 'SISTEMA DE SEGURIDAD ACTIVADO: Analiza cada píxel de la imagen actual. Busca específicamente: 1) Obstáculos a nivel del suelo, 2) Bordes o escaleras hacia abajo, 3) Objetos en movimiento (coches, bicis), 4) Altura de techos o ramas. Responde con un aviso de seguridad crítico si encuentras algo, o confirma que el camino parece despejado.';
    }

    if (name === 'describe_camera_view') {
      this.logger.log('Solicitando descripción de cámara...');
      return 'IMAGEN CAPTURADA: Analiza la imagen que acabas de recibir y describe qué hay delante de forma natural para el usuario.';
    }

    if (name === 'toggle_flashlight') {
      const enabled = args['enabled'] as boolean;
      return `Linterna ${enabled ? 'encendida' : 'apagada'} correctamente.`;
    }

    if (name === 'switch_camera') {
      const direction = args['direction'] as string;
      return `Cámara cambiada a ${direction === 'front' ? 'frontal (selfie)' : 'trasera'} correctamente.`;
    }

    if (name === 'display_content') {
      const title = args['title'] as string;
      return `Panel visual "${title}" mostrado correctamente en la pantalla del usuario.`;
    }

    if (name === 'trigger_haptic_feedback') {
      return 'Vibración enviada al dispositivo.';
    }

    if (name === 'mark_place') {
      const label = args['label'] as string;
      const location = await this.locationService.getCurrentLocation();
      this.memory.set(label.toLowerCase(), location);
      return `He recordado que "${label}" está en ${location}.`;
    }

    if (name === 'get_navigation_directions') {
      const destination = args['destination'] as string;
      const origin = await this.locationService.getCurrentLocation(socketId);
      return `Ruta desde tu posición actual (${origin}) hacia "${destination}". Guía al usuario paso a paso usando la cámara para confirmar los puntos de referencia que vayas describiendo.`;
    }

    return `Herramienta "${name}" no implementada.`;
  }

  // ─── generateContent con agentic loop ─────────────────────────────────────

  async generateContent(
    prompt: string,
    imageBase64List?: string[],
    history?: Content[],
  ): Promise<string> {
    const parts: Part[] = [{ text: prompt }];
    if (imageBase64List?.length) {
      for (const base64 of imageBase64List) {
        parts.push({ inlineData: { mimeType: 'image/jpeg', data: base64 } });
      }
    }

    const contents: Content[] = [
      ...(history ?? []),
      { role: 'user' as const, parts },
    ];

    // Agentic loop: hasta 5 iteraciones de tool use
    for (let i = 0; i < 5; i++) {
      const response = await this.generateContentWithModelFallback({
        model: this.modelName,
        contents,
        config: {
          maxOutputTokens: this.maxOutputTokens,
          temperature: this.temperature,
          tools: AGENT_TOOLS,
        },
      });

      const candidate = response.candidates?.[0];
      const responseParts = candidate?.content?.parts ?? [];

      // Si hay function calls, ejecutarlas y continuar
      const functionCalls = responseParts.filter((p) => p.functionCall);
      if (!functionCalls.length) {
        return response.text ?? '';
      }

      // Añadir respuesta del modelo al historial
      contents.push({ role: 'model' as const, parts: responseParts });

      // Ejecutar todas las tools y añadir resultados
      const toolResultParts: Part[] = await Promise.all(
        functionCalls.map(async (p) => {
          const { name, args } = p.functionCall!;
          const toolName = name ?? 'unknown';
          this.logger.log(`Function call: ${toolName}(${JSON.stringify(args)})`);
          const result = await this.executeTool(toolName, args as Record<string, unknown>);
          return {
            functionResponse: {
              name: toolName,
              response: { content: result },
            },
          } as Part;
        }),
      );

      contents.push({ role: 'user' as const, parts: toolResultParts });
    }

    return '';
  }

  // ─── generateContentStream con agentic loop ────────────────────────────────

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

    const contents: Content[] = [
      ...(history ?? []),
      { role: 'user' as const, parts },
    ];

    const callConfig = {
      maxOutputTokens: this.maxOutputTokens,
      temperature: this.temperature,
      tools: AGENT_TOOLS,
    };

    // Agentic loop con streaming en la respuesta final
    for (let i = 0; i < 5; i++) {
      // Primero hacemos llamada no-stream para detectar function calls
      const response = await this.generateContentWithModelFallback({
        model: this.modelName,
        contents,
        config: callConfig,
      });

      const candidate = response.candidates?.[0];
      const responseParts = candidate?.content?.parts ?? [];
      const functionCalls = responseParts.filter((p) => p.functionCall);

      if (!functionCalls.length) {
        // Sin tool calls: hacer streaming de la respuesta final
        const streamResult = await this.generateContentStreamWithModelFallback({
          model: this.modelName,
          contents,
          config: callConfig,
        });
        for await (const chunk of streamResult) {
          const text = chunk.text ?? '';
          if (text) onChunk(text);
        }
        return;
      }

      // Notificar al cliente que se está buscando
      onChunk('[Buscando información…]');

      contents.push({ role: 'model' as const, parts: responseParts });

      const toolResultParts: Part[] = await Promise.all(
        functionCalls.map(async (p) => {
          const { name, args } = p.functionCall!;
          const toolName = name ?? 'unknown';
          this.logger.log(`Function call: ${toolName}(${JSON.stringify(args)})`);
          const result = await this.executeTool(toolName, args as Record<string, unknown>);
          return {
            functionResponse: {
              name: toolName,
              response: { content: result },
            },
          } as Part;
        }),
      );

      contents.push({ role: 'user' as const, parts: toolResultParts });
    }
  }

  // ─── processAudio ──────────────────────────────────────────────────────────

  async processAudio(audioBase64: string, mimeType: string): Promise<string> {
    const response = await this.generateContentWithModelFallback({
      model: this.modelName,
      contents: [{
        role: 'user' as const,
        parts: [
          {
            text: 'Transcribe el audio exactamente. Devuelve solo el texto transcrito, sin prefijos ni explicaciones.',
          },
          { inlineData: { mimeType, data: audioBase64 } },
        ],
      }],
    });

    return response.text ?? '';
  }
}
