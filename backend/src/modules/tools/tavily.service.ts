import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

export interface SearchResult {
  title: string;
  url: string;
  content: string;
}

interface BraveWebResult {
  title?: string;
  url?: string;
  description?: string;
}

interface BraveSearchResponse {
  web?: {
    results?: BraveWebResult[];
  };
}

@Injectable()
export class TavilyService {
  private readonly logger = new Logger(TavilyService.name);
  private readonly apiKey: string;

  constructor(private readonly configService: ConfigService) {
    const apiKey = this.configService.get<string>('BRAVE_SEARCH_API_KEY');
    if (!apiKey) throw new Error('BRAVE_SEARCH_API_KEY no está configurada');
    this.apiKey = apiKey;
  }

  async search(query: string, maxResults = 5): Promise<SearchResult[]> {
    this.logger.log(`Ejecutando WebSearch para: "${query}"`);
    try {
      const url = `https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=${maxResults}`;
      const response = await fetch(url, {
        headers: {
          'Accept': 'application/json',
          'Accept-Encoding': 'gzip',
          'X-Subscription-Token': this.apiKey,
        },
      });

      if (!response.ok) {
        throw new Error(`Brave Search API error: ${response.status} ${response.statusText}`);
      }

      const data = (await response.json()) as BraveSearchResponse;
      const results: SearchResult[] = (data.web?.results ?? []).map((r) => ({
        title: r.title ?? '',
        url: r.url ?? '',
        content: (r.description ?? '').substring(0, 800),
      }));

      this.logger.log(`WebSearch finalizado: ${results.length} resultados encontrados.`);
      return results;
    } catch (e) {
      this.logger.error(`Error crítico en WebSearch: ${e.message}`);
      return [];
    }
  }
}
