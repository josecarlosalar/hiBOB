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

  async search(query: string, maxResults = 5): Promise<SearchResult[]> {
    this.logger.log(`Búsqueda Tavily: "${query}"`);
    const response = await this.client.search(query, {
      maxResults,
      includeAnswer: false,
    });

    return (response.results ?? []).map((r) => ({
      title: r.title ?? '',
      url: r.url ?? '',
      content: r.content ?? '',
    }));
  }
}
