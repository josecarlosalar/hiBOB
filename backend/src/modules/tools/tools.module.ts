import { Module } from '@nestjs/common';
import { TavilyService } from './tavily.service';

@Module({
  providers: [TavilyService],
  exports: [TavilyService],
})
export class ToolsModule {}
