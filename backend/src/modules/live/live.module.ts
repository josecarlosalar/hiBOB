import { Module } from '@nestjs/common';
import { LiveGateway } from './live.gateway';
import { AiModule } from '../ai/ai.module';
import { ToolsModule } from '../tools/tools.module';

@Module({
  imports: [AiModule, ToolsModule],
  providers: [LiveGateway],
})
export class LiveModule {}
