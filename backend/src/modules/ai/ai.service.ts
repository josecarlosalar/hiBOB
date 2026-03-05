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

const AGENT_TOOLS: Tool[] = [
  {
    functionDeclarations: [
      WEB_SEARCH_FUNCTION,
      GET_LOCATION_FUNCTION,
      DETECT_HAZARDS_FUNCTION,
      TOGGLE_FLASHLIGHT_FUNCTION,
      TRIGGER_HAPTIC_FEEDBACK_FUNCTION,
      MARK_PLACE_FUNCTION,
      GET_DIRECTIONS_FUNCTION,
    ],
  },
];

// ─── Interfaces para Live API ────────────────────────────────────────────────

export interface LiveSessionOptions {
  systemInstruction?: string;
}

/**
 * Sesión Live con Gemini usando el SDK oficial @google/genai.
 * Usa g.live.connect() que gestiona internamente el protocolo WebSocket.
 */
export class GeminiLiveSession extends EventEmitter {
  private session: any; // LiveSession del SDK
  private readonly logger = new Logger(GeminiLiveSession.name);
  private closed = false;

  constructor(
    private readonly ai: GoogleGenAI,
    private readonly modelId: string,
    private readonly options: LiveSessionOptions = {},
  ) {
    super();
  }

  async connect(): Promise<void> {
    // En Vertex AI, el nombre del modelo a veces no requiere el prefijo 'models/' 
    // o requiere la versión específica. Probamos con el string más compatible.
    const model = 'gemini-2.0-flash-001';

    this.session = await this.ai.live.connect({
      model: model,
      config: {
        responseModalities: [Modality.AUDIO],
        systemInstruction: {
          parts: [{ text: this.options.systemInstruction || 'Eres hiBOB, un asistente amable para personas con discapacidad visual. Responde de forma concisa y natural.' }],
        },
        speechConfig: {
          voiceConfig: { prebuiltVoiceConfig: { voiceName: 'Aoede' } },
        },
        inputAudioTranscription: {},
        outputAudioTranscription: {},
        tools: AGENT_TOOLS,
      },
      callbacks: {
        onmessage: (msg: any) => {
          if (!this.closed) this._handleSdkMessage(msg);
        },
        onerror: (err: any) => {
          this.logger.error(`Error en Gemini: ${err.message || err.error || err}`);
          if (!this.closed) this.emit('error', err);
        },
        onclose: () => {
          this.logger.warn('Gemini Live SDK: loop cerrado');
          if (!this.closed) {
            this.closed = true;
            this.emit('close');
          }
        }
      },
    });
    this.logger.log('GeminiLiveSession conectada via SDK');
  }

  private _handleSdkMessage(msg: any) {
    this.logger.log(`[SDK MSG] Keys: ${Object.keys(msg).join(',')} | raw: ${JSON.stringify(msg).substring(0, 200)}`);

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
            this.logger.log(`Gemini Audio Part: ${part.inlineData.data.length} bytes`);
            this.emit('audio', part.inlineData.data);
          }
        }
      }
      if (turnComplete) {
        this.logger.log('Gemini Turn Complete');
        this.emit('done');
      }
      if (interrupted) {
        this.logger.warn('Gemini Interrupted');
        this.emit('interruption');
      }
    }

    // toolCall: llamadas a herramientas del agente
    if (msg.toolCall) {
      this.logger.log(`Gemini Tool Call: ${JSON.stringify(msg.toolCall)}`);
      this.emit('tool_call', msg.toolCall);
    }
  }

  sendAudio(base64Audio: string) {
    if (!this.session || this.closed) return;
    try {
      this.session.sendRealtimeInput({
        audio: { data: base64Audio, mimeType: 'audio/pcm;rate=16000' },
      });
    } catch (err) {
      this.logger.error(`Error en sendAudio: ${err.message}`);
    }
  }

  sendImage(base64Image: string) {
    if (!this.session || this.closed) return;
    try {
      // Para frames individuales de cámara, el SDK prefiere enviarlos como parte 
      // del contenido del cliente para asegurar que el modelo los procese en el turno actual.
      this.session.sendClientContent({
        turns: [{
          role: 'user',
          parts: [{
            inlineData: {
              data: base64Image,
              mimeType: 'image/jpeg'
            }
          }]
        }],
        turnComplete: false,
      });
    } catch (err) {
      this.logger.error(`Error en sendImage: ${err.message}`);
    }
  }

  sendText(text: string) {
    if (!this.session || this.closed) return;
    try {
      this.session.sendClientContent({
        turns: [{ role: 'user', parts: [{ text }] }],
        turnComplete: false,
      });
    } catch (err) {
      this.logger.error(`Error en sendText: ${err.message}`);
    }
  }

  /** Señaliza a Gemini que el turno del usuario ha terminado y debe responder. */
  signalTurnComplete() {
    if (!this.session || this.closed) return;
    try {
      this.session.sendClientContent({ turnComplete: true });
    } catch (err) {
      this.logger.error(`Error en signalTurnComplete: ${err.message}`);
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
}

// ─── Servicio ─────────────────────────────────────────────────────────────────

@Injectable()
export class AiService implements OnModuleInit {
  private readonly logger = new Logger(AiService.name);
  private ai: GoogleGenAI;
  private modelName: string;
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

    this.logger.log(`Google GenAI inicializado: proyecto=${project}, modelo=${this.modelName}`);
  }

  // ─── Live Session ──────────────────────────────────────────────────────────

  async createLiveSession(options?: LiveSessionOptions): Promise<GeminiLiveSession> {
    // Usar el SDK @google/genai con Vertex AI (cuenta de servicio GCP).
    // Cumple los requisitos del hackathon: SDK oficial de Google GenAI + Vertex AI.
    const project = this.configService.get<string>('GCP_PROJECT_ID');
    const location = this.configService.get<string>('GCP_LOCATION', 'us-central1');

    const liveAi = new GoogleGenAI({ vertexai: true, project, location });
    // Modelo nativo de audio para Live API en Vertex AI (hackathon requirement)
    const modelId = 'gemini-live-2.5-flash-preview-native-audio-09-2025';

    const session = new GeminiLiveSession(liveAi, modelId, options);
    await session.connect();
    return session;
  }

  // ─── Llamada a herramienta ─────────────────────────────────────────────────

  private async executeTool(
    name: string,
    args: Record<string, unknown>,
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
      return await this.locationService.getCurrentLocation();
    }

    if (name === 'detect_safety_hazards') {
      this.logger.log('Ejecutando escaneo de seguridad detallado...');
      return 'SISTEMA DE SEGURIDAD ACTIVADO: Analiza cada píxel de la imagen actual. Busca específicamente: 1) Obstáculos a nivel del suelo, 2) Bordes o escaleras hacia abajo, 3) Objetos en movimiento (coches, bicis), 4) Altura de techos o ramas. Responde con un aviso de seguridad crítico si encuentras algo, o confirma que el camino parece despejado.';
    }

    if (name === 'toggle_flashlight') {
      const enabled = args['enabled'] as boolean;
      return `Linterna ${enabled ? 'encendida' : 'apagada'} correctamente.`;
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
      // Para el hackathon, simulamos una ruta inteligente. 
      // En producción aquí iría una llamada a Google Maps Directions API.
      return `Ruta calculada hacia ${destination}. Instrucción actual: Camina 50 metros recto hasta ver un cartel azul y gira a la derecha. Yo te guiaré usando la cámara.`;
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
      const response = await this.ai.models.generateContent({
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
      const response = await this.ai.models.generateContent({
        model: this.modelName,
        contents,
        config: callConfig,
      });

      const candidate = response.candidates?.[0];
      const responseParts = candidate?.content?.parts ?? [];
      const functionCalls = responseParts.filter((p) => p.functionCall);

      if (!functionCalls.length) {
        // Sin tool calls: hacer streaming de la respuesta final
        const streamResult = await this.ai.models.generateContentStream({
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
    const response = await this.ai.models.generateContent({
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
