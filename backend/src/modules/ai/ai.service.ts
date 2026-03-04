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

const AGENT_TOOLS: Tool[] = [{ functionDeclarations: [WEB_SEARCH_FUNCTION] }];

// ─── Servicio ─────────────────────────────────────────────────────────────────

@Injectable()
export class AiService implements OnModuleInit {
  private readonly logger = new Logger(AiService.name);
  private ai: GoogleGenAI;
  private modelName: string;
  private maxOutputTokens: number;
  private temperature: number;

  constructor(
    private readonly configService: ConfigService,
    private readonly tavilyService: TavilyService,
  ) {}

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

    this.logger.log(`Google GenAI inicializado: proyecto=${project}, modelo=${this.modelName}`);
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
