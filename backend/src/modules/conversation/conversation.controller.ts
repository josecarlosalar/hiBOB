import {
  Body,
  Controller,
  Get,
  Param,
  Post,
  Req,
  Res,
} from '@nestjs/common';
import type { Request, Response } from 'express';
import { ConversationService } from './conversation.service';
import { CreateMessageDto } from './dto/create-message.dto';

type AuthRequest = Request & { user: { uid: string } };

@Controller('conversation')
export class ConversationController {
  constructor(private readonly conversationService: ConversationService) {}

  @Get()
  list(@Req() req: AuthRequest): Promise<unknown[]> {
    return this.conversationService.listConversations(req.user.uid);
  }

  @Post('chat')
  chat(@Body() dto: CreateMessageDto, @Req() req: AuthRequest) {
    return this.conversationService.chat(dto, req.user.uid);
  }

  @Post('chat/stream')
  async chatStream(
    @Body() dto: CreateMessageDto,
    @Req() req: AuthRequest,
    @Res() res: Response,
  ) {
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');

    await this.conversationService.chatStream(dto, req.user.uid, (chunk) => {
      res.write(`data: ${JSON.stringify({ text: chunk })}\n\n`);
    });

    res.write('data: [DONE]\n\n');
    res.end();
  }

  @Post('voice')
  // Endpoint REST legado (no Live API): mantiene fallback audio/m4a.
  voice(
    @Body() dto: { conversationId: string; audioBase64: string; mimeType?: string },
    @Req() req: AuthRequest,
  ) {
    return this.conversationService.processVoice(
      dto.conversationId,
      dto.audioBase64,
      dto.mimeType ?? 'audio/m4a',
      req.user.uid,
    );
  }

  @Get(':conversationId/messages')
  async getMessages(
    @Param('conversationId') conversationId: string,
  ): Promise<unknown[]> {
    return this.conversationService.getMessages(conversationId);
  }
}
