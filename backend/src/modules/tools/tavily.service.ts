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
    this.logger.log(`Ejecutando WebSearch para: "${query}"`);
    try {
      const response = await this.client.search(query, {
        maxResults,
        includeAnswer: true,
        searchDepth: 'advanced', // Mayor profundidad para encontrar resultados difíciles
      });

      const results: SearchResult[] = (response.results ?? []).map((r) => ({
        title: r.title ?? '',
        url: r.url ?? '',
        content: (r.content ?? '').substring(0, 800) + '...',
      }));

      // Si Tavily nos da una respuesta directa, la añadimos como el primer resultado "maestro"
      if (response.answer) {
        results.unshift({
          title: 'Resumen de búsqueda',
          url: 'N/A',
          content: response.answer,
        });
      }

      this.logger.log(`WebSearch finalizado: ${results.length} resultados encontrados.`);
      return results;
    } catch (e) {
      this.logger.error(`Error crítico en WebSearch: ${e.message}`);
      return [];
    }
  }
}
