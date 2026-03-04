import { Module } from '@nestjs/common';
import { TavilyService } from './tavily.service';
import { LocationService } from './location.service';

@Module({
  providers: [TavilyService, LocationService],
  exports: [TavilyService, LocationService],
})
export class ToolsModule { }
