import { Body, Controller, Get, Param, Post } from '@nestjs/common';
import { ConversationService } from './conversation.service';
import { CreateMessageDto } from './dto/create-message.dto';

@Controller('conversation')
export class ConversationController {
  constructor(private readonly conversationService: ConversationService) {}

  @Post('chat')
  chat(@Body() dto: CreateMessageDto) {
    return this.conversationService.chat(dto);
  }

  @Get(':conversationId/messages')
  async getMessages(
    @Param('conversationId') conversationId: string,
  ): Promise<unknown[]> {
    return this.conversationService.getMessages(conversationId);
  }
}
