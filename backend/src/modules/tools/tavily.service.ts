import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { tavily } from '@tavily/core';

export interface SearchResult {
  title: string;
  url: string;
  content: string;
}

@Injectable()
export class TavilyService {
  private readonly logger = new Logger(TavilyService.name);
  private readonly client: ReturnType<typeof tavily>;

  constructor(private readonly configService: ConfigService) {
    const apiKey = this.configService.get<string>('TAVILY_API_KEY');
    if (!apiKey) throw new Error('TAVILY_API_KEY no está configurada');
    this.client = tavily({ apiKey });
  }

  async search(query: string, maxResults = 3): Promise<SearchResult[]> {
    this.logger.log(`Búsqueda Tavily (limitada): "${query}"`);
    try {
      const response = await this.client.search(query, {
        maxResults,
        includeAnswer: true,
        searchDepth: 'basic',
      });

      return (response.results ?? []).map((r) => ({
        title: r.title ?? '',
        url: r.url ?? '',
        // Limitamos el contenido a 600 caracteres por resultado para no saturar el WebSocket
        content: (r.content ?? '').substring(0, 600) + '...',
      }));
    } catch (e) {
      this.logger.error(`Error en búsqueda Tavily: ${e.message}`);
      return [];
    }
  }
}
