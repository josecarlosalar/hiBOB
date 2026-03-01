import { Body, Controller, Post, Res } from '@nestjs/common';
import type { Response } from 'express';
import { AiService } from './ai.service';
import { GenerateContentDto } from './dto/generate-content.dto';

@Controller('ai')
export class AiController {
  constructor(private readonly aiService: AiService) {}

  @Post('generate')
  async generate(@Body() dto: GenerateContentDto) {
    const text = await this.aiService.generateContent(
      dto.prompt,
      dto.imageBase64List,
    );
    return { text };
  }

  @Post('stream')
  async stream(@Body() dto: GenerateContentDto, @Res() res: Response) {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');

    await this.aiService.generateContentStream(
      dto.prompt,
      (chunk) => res.write(`data: ${JSON.stringify({ text: chunk })}\n\n`),
      dto.imageBase64List,
    );

    res.write('data: [DONE]\n\n');
    res.end();
  }
}
