import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  VertexAI,
  GenerativeModel,
  Content,
  Part,
} from '@google-cloud/vertexai';

@Injectable()
export class AiService implements OnModuleInit {
  private readonly logger = new Logger(AiService.name);
  private vertexAI: VertexAI;
  private model: GenerativeModel;

  constructor(private readonly configService: ConfigService) {}

  onModuleInit() {
    const project = this.configService.get<string>('GCP_PROJECT_ID');
    const location = this.configService.get<string>('GCP_LOCATION', 'us-central1');
    const modelName = this.configService.get<string>('GEMINI_MODEL', 'gemini-2.5-flash');

    this.vertexAI = new VertexAI({ project, location });

    this.model = this.vertexAI.getGenerativeModel({
      model: modelName,
      generationConfig: {
        maxOutputTokens: parseInt(
          this.configService.get<string>('GEMINI_MAX_OUTPUT_TOKENS', '8192'),
        ),
        temperature: parseFloat(
          this.configService.get<string>('GEMINI_TEMPERATURE', '1.0'),
        ),
      },
    });

    this.logger.log(`Vertex AI inicializado: proyecto=${project}, modelo=${modelName}`);
  }

  async generateContent(
    prompt: string,
    imageBase64List?: string[],
    history?: Content[],
  ): Promise<string> {
    const parts: Part[] = [{ text: prompt }];

    if (imageBase64List?.length) {
      for (const base64 of imageBase64List) {
        parts.push({
          inlineData: {
            mimeType: 'image/jpeg',
            data: base64,
          },
        });
      }
    }

    const request = {
      contents: [
        ...(history ?? []),
        { role: 'user' as const, parts },
      ],
    };

    const response = await this.model.generateContent(request);
    const candidate = response.response.candidates?.[0];
    return candidate?.content?.parts?.[0]?.text ?? '';
  }

  async generateContentStream(
    prompt: string,
    onChunk: (text: string) => void,
    imageBase64List?: string[],
  ): Promise<void> {
    const parts: Part[] = [{ text: prompt }];

    if (imageBase64List?.length) {
      for (const base64 of imageBase64List) {
        parts.push({
          inlineData: { mimeType: 'image/jpeg', data: base64 },
        });
      }
    }

    const streamResult = await this.model.generateContentStream({
      contents: [{ role: 'user', parts }],
    });

    for await (const chunk of streamResult.stream) {
      const text = chunk.candidates?.[0]?.content?.parts?.[0]?.text ?? '';
      if (text) onChunk(text);
    }
  }
}
