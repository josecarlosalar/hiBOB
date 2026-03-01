import { Module } from '@nestjs/common';
import { LiveGateway } from './live.gateway';
import { AiModule } from '../ai/ai.module';

@Module({
  imports: [AiModule],
  providers: [LiveGateway],
})
export class LiveModule {}
