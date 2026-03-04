import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  GoogleGenAI,
  Content,
  Part,
  Tool,
  FunctionDeclaration,
  Type,
} from '@google/genai';
import { TavilyService } from '../tools/tavily.service';
import { LocationService } from '../tools/location.service';
import WebSocket from 'ws';
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

export class GeminiLiveSession extends EventEmitter {
  private ws: WebSocket;
  private readonly logger = new Logger(GeminiLiveSession.name);

  constructor(
    private readonly url: string,
    private readonly token: string,
    private readonly modelPath: string,
    private readonly options: LiveSessionOptions = {},
  ) {
    super();
  }

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url, {
        headers: { Authorization: `Bearer ${this.token}` },
      });

      this.ws.on('open', () => {
        this.logger.log('Conexión con Gemini Live API establecida');
        this.sendSetup();
        resolve();
      });

      this.ws.on('message', (data) => {
        const message = JSON.parse(data.toString());
        this.handleMessage(message);
      });

      this.ws.on('error', (err) => {
        this.logger.error(`Error en Gemini Live API: ${err.message}`);
        this.emit('error', err);
        reject(err);
      });

      this.ws.on('close', (code, reason) => {
        this.logger.warn(`Conexión con Gemini Live API cerrada: code=${code} reason=${reason?.toString()}`);
        this.emit('close');
      });
    });
  }

  private sendSetup() {
    const setupMsg = {
      setup: {
        model: this.modelPath,
        generation_config: {
          response_modalities: ['AUDIO', 'TEXT'],
        },
        tools: AGENT_TOOLS,
        system_instruction: {
          role: 'system',
          parts: [{ text: this.options.systemInstruction || 'Eres hiBOB, un asistente amable para personas con discapacidad visual. Responde de forma concisa y natural.' }],
        },
      },
    };
    this.ws.send(JSON.stringify(setupMsg));
  }

  private handleMessage(msg: any) {
    if (msg.serverContent) {
      const { modelTurn, turnComplete, interrupted } = msg.serverContent;

      if (modelTurn) {
        if (modelTurn.parts) {
          for (const part of modelTurn.parts) {
            if (part.text) this.emit('text', part.text);
            if (part.inlineData) this.emit('audio', part.inlineData.data);
          }
        }
      }

      if (turnComplete) this.emit('done');
      if (interrupted) this.emit('interruption');
    }

    if (msg.toolCall) {
      this.emit('tool_call', msg.toolCall);
    }
  }

  sendAudio(base64Audio: string) {
    if (this.ws.readyState !== WebSocket.OPEN) return;
    const msg = {
      realtimeInput: {
        mediaChunks: [{ mimeType: 'audio/pcm;rate=16000', data: base64Audio }],
      },
    };
    this.ws.send(JSON.stringify(msg));
  }

  sendImage(base64Image: string) {
    if (this.ws.readyState !== WebSocket.OPEN) return;
    const msg = {
      realtimeInput: {
        mediaChunks: [{ mimeType: 'image/jpeg', data: base64Image }],
      },
    };
    this.ws.send(JSON.stringify(msg));
  }

  sendText(text: string) {
    if (this.ws.readyState !== WebSocket.OPEN) return;
    const msg = {
      clientContent: {
        turns: [{ role: 'user', parts: [{ text }] }],
        turnComplete: false,
      },
    };
    this.ws.send(JSON.stringify(msg));
  }

  /** Señaliza a Gemini que el turno del usuario ha terminado y debe responder. */
  signalTurnComplete() {
    if (this.ws.readyState !== WebSocket.OPEN) return;
    const msg = { clientContent: { turnComplete: true } };
    this.ws.send(JSON.stringify(msg));
  }

  sendToolResponse(toolResponses: any[]) {
    if (this.ws.readyState !== WebSocket.OPEN) return;
    const msg = { toolResponse: { functionResponses: toolResponses } };
    this.ws.send(JSON.stringify(msg));
  }

  close() {
    this.ws?.close();
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
    const project = this.configService.get<string>('GCP_PROJECT_ID');
    // La Live API de Gemini en Vertex AI solo está disponible en us-central1
    const liveLocation = 'us-central1';
    const modelId = 'gemini-2.0-flash-live-preview-04-09'; // Modelo compatible con Live API

    const url = `wss://${liveLocation}-aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent?project=${project}&location=${liveLocation}`;

    const client = await this.auth.getClient();
    const tokenResponse = await client.getAccessToken();
    const token = tokenResponse.token;

    if (!token) throw new Error('No se pudo obtener el token de acceso de GCP');

    const modelPath = `projects/${project}/locations/${liveLocation}/publishers/google/models/${modelId}`;
    const session = new GeminiLiveSession(url, token, modelPath, options);
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
